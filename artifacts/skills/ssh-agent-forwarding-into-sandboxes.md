# SSH agent forwarding into sandboxes

## Problem

Git push/pull via SSH fails inside sandboxes because the SSH agent socket isn't accessible and openssh isn't in PATH.

## Requirements

Three things must be forwarded for SSH to work:

### 1. SSH keys (read-only)

```bash
# bubblewrap
--ro-bind "$HOME/.ssh" "$sandbox_home/.ssh"

# nspawn
--bind-ro="$real_home/.ssh":/home/sandbox/.ssh
```

### 2. SSH agent socket + env var

The socket file must be bind-mounted AND `SSH_AUTH_SOCK` must point to it:

```bash
# bubblewrap (socket stays at original path)
--ro-bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK"
--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK"

# nspawn (remap to container path)
--bind-ro="$SSH_AUTH_SOCK":/run/user/$real_uid/ssh-agent.sock
--setenv=SSH_AUTH_SOCK=/run/user/$real_uid/ssh-agent.sock
```

### 3. openssh in PATH

Add `openssh` to the sandbox's package set. Without it, git's SSH transport fails with `ssh: command not found` even if keys and agent are forwarded.

### 4. Git config

Forward both possible locations (traditional and home-manager):

```bash
--ro-bind "$HOME/.gitconfig" "$sandbox_home/.gitconfig"       # traditional
--ro-bind "$HOME/.config/git" "$sandbox_home/.config/git"     # home-manager
```

## Verification

Inside the sandbox:
```bash
ssh-add -l                    # Should list keys from agent
ssh -T git@github.com         # Should authenticate
git push                      # Should work
```

## Gotcha: host key verification

First SSH connection to a new host will prompt for host key verification. If running non-interactively, the sandbox's `~/.ssh/known_hosts` is ephemeral (lost on exit). For automated use, consider forwarding the host's `known_hosts` file.
