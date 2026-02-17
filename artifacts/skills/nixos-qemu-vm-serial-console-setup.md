# NixOS QEMU VM serial console setup

## Problem

When building a NixOS QEMU VM where the primary interaction is via serial console (e.g., a CLI tool in the user's terminal while a GUI runs in the QEMU window), getting serial output working requires three things that aren't obvious.

## Solution

### 1. Add `-serial stdio` to QEMU options

```nix
virtualisation.qemu.options = [ "-serial" "stdio" ];
```

Without this, QEMU doesn't connect the guest's serial port to the host's stdio.

### 2. Reverse the console order

By default, NixOS QEMU VMs set `virtualisation.qemu.consoles` with `ttyS0` first and `tty0` last. Linux uses the **last** `console=` parameter as the primary console. To make serial the primary:

```nix
virtualisation.qemu.consoles = [ "tty0" "ttyS0,115200n8" ];
```

This puts `ttyS0` last, making it the primary console where boot messages and login prompts appear.

### 3. Auto-login on serial console

Use NixOS's built-in getty autologin rather than a custom systemd service (which has TTY management issues like TTYReset and ordering problems):

```nix
services.getty.autologinUser = "sandbox";
```

For running a specific command on serial login, use `environment.interactiveShellInit` with a tty guard:

```nix
environment.interactiveShellInit = ''
  if [[ "$(tty)" == /dev/ttyS0 ]]; then
    cd /project 2>/dev/null || true
    # ... setup env vars ...
    if [[ -f /mnt/meta/entrypoint ]]; then
      entrypoint=$(cat /mnt/meta/entrypoint)
      if [[ "$entrypoint" != "bash" ]]; then
        exec $entrypoint
      fi
    fi
  fi
'';
```

The `$(tty) == /dev/ttyS0` guard ensures this only runs on the serial console, not on the graphical tty0.

## Gotcha: custom systemd service on ttyS0

Don't try to create a custom `systemd.services.claude-serial` with `StandardInput=tty` and `TTYPath=/dev/ttyS0`. This fights with getty for TTY ownership and causes issues with TTYReset, TTYVHangup, and service ordering. The getty + interactiveShellInit approach is simpler and works reliably.
