# Dropping privileges in systemd-nspawn without PAM

## Problem

When running a process as root inside a systemd-nspawn container and needing to drop to a regular user, the obvious tools — `su`, `runuser`, `sudo` — all fail because they depend on PAM (`/etc/pam.d`), which isn't present in a minimal ephemeral container root.

Error: `runuser: PAM authentication failed`

## Solution

Use `setpriv` from `util-linux`:

```bash
setpriv --reuid=$real_uid --regid=$real_gid --init-groups -- bash -c 'cd /project && exec $ENTRYPOINT'
```

- `--reuid` / `--regid`: set real+effective UID/GID
- `--init-groups`: initialize supplementary groups from `/etc/group`
- No PAM dependency — pure syscall-based privilege drop

**Important**: Use the real user's UID/GID (resolved from `SUDO_USER`), not hardcoded 1000. Hardcoding causes file ownership mismatches when the host user has a different UID.

```bash
real_uid="$(id -u "${SUDO_USER:-${USER}}")"
real_gid="$(id -g "${SUDO_USER:-${USER}}")"
```

## Container setup requirements

The container root needs `/etc/passwd` and `/etc/group` with the target user at the correct UID:

```bash
echo "sandbox:x:$real_uid:$real_gid:sandbox:/home/sandbox:/bin/bash" >> "$container_root/etc/passwd"
echo "sandbox:x:$real_gid:" >> "$container_root/etc/group"
```

And `/etc/nsswitch.conf` for name resolution:

```bash
echo "passwd: files" > "$container_root/etc/nsswitch.conf"
echo "group: files" >> "$container_root/etc/nsswitch.conf"
```

## NixOS context

In a NixOS-based nspawn container, binaries live under the `toplevel` closure. Reference them with full paths:

```bash
${toplevel}/sw/bin/setpriv --reuid=$real_uid --regid=$real_gid --init-groups -- ${toplevel}/sw/bin/bash -c '...'
```

Add `util-linux` to `environment.systemPackages` in the container's NixOS config.
