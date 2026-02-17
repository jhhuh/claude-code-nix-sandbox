# Sandbox NixOS Module

For NixOS users, a declarative module installs sandbox backends as system packages.

## Usage

```nix
# flake.nix
{
  inputs.claude-sandbox.url = "github:jhhuh/claude-code-nix-sandbox";

  outputs = { nixpkgs, claude-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-sandbox.nixosModules.default
        {
          services.claude-sandbox = {
            enable = true;
            container.enable = true;
            vm.enable = true;
          };
        }
      ];
    };
  };
}
```

## Options

### `services.claude-sandbox.enable`

Whether to install Claude Code sandbox wrappers.

- Type: `bool`
- Default: `false`

### `services.claude-sandbox.network`

Allow network access from sandboxes. Applies to all enabled backends.

- Type: `bool`
- Default: `true`

### `services.claude-sandbox.bubblewrap.enable`

Install the bubblewrap sandbox. Enabled by default when the module is active.

- Type: `bool`
- Default: `true`

### `services.claude-sandbox.bubblewrap.extraPackages`

Extra packages available inside the bubblewrap sandbox.

- Type: `list of package`
- Default: `[]`

### `services.claude-sandbox.container.enable`

Install the systemd-nspawn container sandbox.

- Type: `bool`
- Default: `false`

### `services.claude-sandbox.container.extraModules`

Extra NixOS modules for the container.

- Type: `list of anything`
- Default: `[]`

### `services.claude-sandbox.vm.enable`

Install the QEMU VM sandbox.

- Type: `bool`
- Default: `false`

### `services.claude-sandbox.vm.extraModules`

Extra NixOS modules for the VM.

- Type: `list of anything`
- Default: `[]`

## Implied configuration

When enabled, the module also sets:

- `nixpkgs.config.allowUnfree = true` — may be required depending on claude-code source
- `security.unprivilegedUsernsClone = true` — when bubblewrap is enabled (required for user namespaces)

## Example with customization

```nix
services.claude-sandbox = {
  enable = true;
  network = false;  # isolate all backends

  bubblewrap.extraPackages = with pkgs; [ python3 nodejs ];

  container.enable = true;
  container.extraModules = [{
    environment.systemPackages = with pkgs; [ python3 ];
  }];

  vm.enable = true;
  vm.extraModules = [{
    virtualisation.memorySize = 8192;
  }];
};
```
