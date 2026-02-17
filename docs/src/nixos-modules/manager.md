# Manager NixOS Module

Deploy the remote sandbox manager as a systemd service.

## Usage

```nix
# flake.nix
{
  inputs.claude-sandbox.url = "github:jhhuh/claude-code-nix-sandbox";

  outputs = { nixpkgs, claude-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-sandbox.nixosModules.manager
        {
          services.claude-sandbox-manager = {
            enable = true;
            sandboxPackages = [
              claude-sandbox.packages.x86_64-linux.default
            ];
          };
        }
      ];
    };
  };
}
```

## Options

### `services.claude-sandbox-manager.enable`

Enable the Claude Sandbox Manager web dashboard.

- Type: `bool`
- Default: `false`

### `services.claude-sandbox-manager.listenAddress`

Address and port for the manager to listen on.

- Type: `str`
- Default: `"127.0.0.1:3000"`

### `services.claude-sandbox-manager.stateDir`

Directory for persistent state (`state.json`).

- Type: `str`
- Default: `"/var/lib/claude-manager"`

### `services.claude-sandbox-manager.user`

System user to run the manager as.

- Type: `str`
- Default: `"claude-manager"`

### `services.claude-sandbox-manager.group`

System group to run the manager as.

- Type: `str`
- Default: `"claude-manager"`

### `services.claude-sandbox-manager.sandboxPackages`

Sandbox backend packages to put on the manager's PATH.

- Type: `list of package`
- Default: `[]`

### `services.claude-sandbox-manager.containerSudoers`

Add a sudoers rule allowing the manager user to run `claude-sandbox-container` without a password. Required if you want the manager to launch container-backend sandboxes.

- Type: `bool`
- Default: `false`

## What the module creates

- A system user and group (`claude-manager` by default)
- A systemd service (`claude-sandbox-manager.service`) that:
  - Sets `MANAGER_LISTEN` and `MANAGER_STATE_DIR` environment variables
  - Puts `sandboxPackages` on PATH
  - Manages `StateDirectory` for persistent data
  - Restarts on failure (5 second delay)
- Optionally, a sudoers rule for the container backend

## Example with container support

```nix
services.claude-sandbox-manager = {
  enable = true;
  listenAddress = "127.0.0.1:3001";
  sandboxPackages = [
    claude-sandbox.packages.x86_64-linux.default
    claude-sandbox.packages.x86_64-linux.container
  ];
  containerSudoers = true;
};
```
