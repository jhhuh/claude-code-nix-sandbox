# QEMU VM backend for Claude Code + Chromium
#
# Usage: claude-sandbox-vm [--shell] <project-dir> [claude args...]
#
# Launches a NixOS VM via QEMU with claude-code and chromium.
# Provides the strongest isolation: separate kernel, full hardware
# virtualization. Claude runs on the serial console (in your terminal),
# Chromium renders in the QEMU display window.
{
  lib,
  writeShellApplication,
  coreutils,
  nixos,
  # Toggle host network access (set false for isolated network)
  network ? true,
  # Additional NixOS modules for the VM
  extraModules ? [ ],
}:

let
  vmSystem = nixos {
    imports = [
      ({ pkgs, modulesPath, ... }: {
        imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

        nixpkgs.config.allowUnfree = true;

        virtualisation = {
          memorySize = 4096;
          cores = 4;
          graphics = true;
          diskImage = "/tmp/claude-sandbox-vm.qcow2";
          vlans = lib.mkIf (!network) [ ];
          qemu.options = [
            # Serial console on host stdio (for claude-code interaction)
            "-serial" "stdio"
          ];
        };

        # Serial console must be last so Linux makes it /dev/console
        virtualisation.qemu.consoles = [ "tty0" "ttyS0,115200n8" ];

        # Project directory via 9p (host path passed at runtime via QEMU_OPTS)
        fileSystems."/project" = {
          device = "project_share";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "msize=104857600" ];
          noCheck = true;
        };

        # Claude auth via 9p (nofail: dir may not exist on host)
        fileSystems."/home/sandbox/.claude" = {
          device = "claude_auth";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "nofail" ];
          noCheck = true;
        };

        # Git config via 9p (nofail: may not exist on host)
        fileSystems."/home/sandbox/.gitconfig" = {
          device = "git_config";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        fileSystems."/home/sandbox/.config/git" = {
          device = "git_config_dir";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        # SSH keys via 9p (nofail: dir may not exist on host)
        fileSystems."/home/sandbox/.ssh" = {
          device = "ssh_dir";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
          noCheck = true;
        };

        # Metadata (entrypoint, API key) via 9p
        fileSystems."/mnt/meta" = {
          device = "claude_meta";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" ];
          noCheck = true;
        };

        # Minimal Xorg + WM for Chromium display (shown in QEMU window)
        services.xserver = {
          enable = true;
          windowManager.openbox.enable = true;
        };
        services.displayManager = {
          autoLogin = {
            enable = true;
            user = "sandbox";
          };
          defaultSession = "none+openbox";
        };

        # Auto-login sandbox user on serial console (ttyS0)
        services.getty.autologinUser = "sandbox";

        # Set up environment for sandbox user's login shell
        environment.interactiveShellInit = ''
          if [[ "$(tty)" == /dev/ttyS0 ]]; then
            # Reconstruct host paths from metadata
            if [[ -f /mnt/meta/host_home ]]; then
              host_home=$(cat /mnt/meta/host_home)
              export HOME="$host_home"
              sudo mkdir -p "$host_home"
              sudo chown sandbox:users "$host_home"
              # Symlink dotfiles from fixed 9p mount to real home path
              for item in .claude .gitconfig .config .ssh; do
                if [[ -e "/home/sandbox/$item" ]]; then
                  ln -sfn "/home/sandbox/$item" "$host_home/$item"
                fi
              done
            fi
            if [[ -f /mnt/meta/host_project ]]; then
              host_project=$(cat /mnt/meta/host_project)
              sudo mkdir -p "$host_project"
              sudo mount --bind /project "$host_project"
            fi

            export DISPLAY=:0
            cd "''${host_project:-/project}" 2>/dev/null || true
            if [[ -f /mnt/meta/apikey ]]; then
              export ANTHROPIC_API_KEY=$(cat /mnt/meta/apikey)
            fi
            # Run entrypoint (exec replaces shell in non-interactive mode)
            if [[ -f /mnt/meta/entrypoint ]]; then
              entrypoint=$(cat /mnt/meta/entrypoint)
              if [[ "$entrypoint" != "bash" ]]; then
                eval exec $entrypoint
              fi
            fi
          fi
        '';

        security.sudo = {
          enable = true;
          wheelNeedsPassword = false;
        };

        users.users.sandbox = {
          isNormalUser = true;
          home = "/home/sandbox";
          uid = 1000;
          extraGroups = [ "video" "audio" "wheel" ];
        };

        environment.systemPackages = with pkgs; [
          claude-code
          chromium
          git
          openssh
          coreutils
          bash
          nix
        ];

        networking = {
          hostName = "claude-sandbox";
          useDHCP = network;
        };

        # Forward host DNS/TLS/fonts config
        environment.etc = {
          "fonts/fonts.conf".source = lib.mkDefault "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
        };

        system.stateVersion = "24.11";
      })
    ] ++ extraModules;
  };

  vmScript = vmSystem.config.system.build.vm;
in
writeShellApplication {
  name = "claude-sandbox-vm";
  runtimeInputs = [ coreutils ];

  text = ''
    shell_mode=false
    if [[ "''${1:-}" == "--shell" ]]; then
      shell_mode=true
      shift
    fi

    if [[ $# -lt 1 ]] || [[ "''${1:-}" == "--help" ]] || [[ "''${1:-}" == "-h" ]]; then
      echo "Usage: claude-sandbox-vm [--shell] <project-dir> [claude args...]" >&2
      echo "  --shell  Drop into bash instead of launching claude" >&2
      exit 1
    fi

    project_dir="$(realpath "$1")"
    shift

    if [[ ! -d "$project_dir" ]]; then
      echo "Error: $project_dir is not a directory" >&2
      exit 1
    fi

    # Create metadata directory (entrypoint + API key)
    meta_dir="$(mktemp -d /tmp/claude-vm-meta.XXXXXX)"
    # Use unique disk image path to avoid collisions between concurrent runs
    NIX_DISK_IMAGE="$(mktemp /tmp/claude-sandbox-vm.XXXXXX.qcow2)"
    export NIX_DISK_IMAGE
    rm -f "$NIX_DISK_IMAGE"  # QEMU creates it; we just need a unique name
    trap 'rm -rf "$meta_dir" "$NIX_DISK_IMAGE"' EXIT

    if [[ "$shell_mode" == true ]]; then
      echo "bash" > "$meta_dir/entrypoint"
    else
      printf '%q ' claude "$@" > "$meta_dir/entrypoint"
    fi

    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      echo "$ANTHROPIC_API_KEY" > "$meta_dir/apikey"
    fi

    # Pass host paths so VM can reconstruct them
    echo "$HOME" > "$meta_dir/host_home"
    echo "$project_dir" > "$meta_dir/host_project"

    # Share project, metadata, and auth dirs via 9p
    qemu_extra=()
    qemu_extra+=(-virtfs "local,path=$project_dir,mount_tag=project_share,security_model=none,id=project_share")
    qemu_extra+=(-virtfs "local,path=$meta_dir,mount_tag=claude_meta,security_model=none,id=claude_meta,readonly=on")

    host_claude_dir="''${HOME}/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      qemu_extra+=(-virtfs "local,path=$host_claude_dir,mount_tag=claude_auth,security_model=none,id=claude_auth")
    fi

    if [[ -f "$HOME/.gitconfig" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.gitconfig,mount_tag=git_config,security_model=none,id=git_config,readonly=on")
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.config/git,mount_tag=git_config_dir,security_model=none,id=git_config_dir,readonly=on")
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      qemu_extra+=(-virtfs "local,path=$HOME/.ssh,mount_tag=ssh_dir,security_model=none,id=ssh_dir,readonly=on")
    fi

    export QEMU_OPTS="''${qemu_extra[*]}"
    exec ${vmScript}/bin/run-claude-sandbox-vm
  '';
}
