# NixOS VM Integration Test with Stub Services

## Pattern

Use `pkgs.testers.nixosTest` (NOT the removed `pkgs.nixosTest`) to write full-stack integration tests for system services. Stub expensive dependencies (like sandbox backends) with simple scripts.

## Setup

```nix
# tests/manager.nix
{ pkgs, managerPackage, ... }:
pkgs.testers.nixosTest {
  name = "manager-test";

  nodes.server = { pkgs, ... }: {
    # Import the service module
    imports = [ ../nix/modules/manager.nix ];

    # Enable the service
    services.my-manager.enable = true;

    # Inject a stub backend — a sleep script that acts like the real thing
    services.my-manager.sandboxPackages = [
      (pkgs.writeShellScriptBin "claude-sandbox" ''
        echo "stub sandbox for $1"
        sleep 300
      '')
    ];

    # Fix: system users default to nologin shell, which breaks tmux
    systemd.services.my-manager.environment.SHELL = "${pkgs.bash}/bin/bash";
  };

  testScript = ''
    server.start()
    server.wait_for_unit("my-manager.service")

    # Test API endpoints
    result = server.succeed("curl -s http://localhost:3000/api/sandboxes")
    assert result == "[]", f"Expected empty list, got {result}"

    # Create, verify, stop, delete...
    server.succeed("curl -s -X POST ...")
  '';
}
```

## Wiring into flake checks

```nix
# flake.nix
checks.${system}.manager-test = pkgs.callPackage ./tests/manager.nix {
  managerPackage = self.packages.${system}.manager;
};
```

Run with: `nix build .#checks.x86_64-linux.manager-test -L`

## Gotchas

1. **`pkgs.testers.nixosTest`** — `pkgs.nixosTest` was removed from nixpkgs. Use the `testers` namespace.

2. **System user shell** — NixOS system users (created by `DynamicUser=true` or `users.users.*.isSystemUser`) default to `/run/current-system/sw/bin/nologin`. Tools like `tmux` that spawn subshells will fail. Fix: set `SHELL` in the service environment.

3. **Stub via `sandboxPackages`** — Create a module option that adds packages to the service's `PATH`. The stub script can be as simple as `sleep 300` if you just need a running process.

4. **Test output** — Use `-L` flag to see test output in real time during `nix build`.

5. **Deprecation warning** — `xorg.xorgserver` is renamed to `xorg-server` in recent nixpkgs. Non-blocking but shows a warning.

## When This Matters

Testing any system service that orchestrates subprocesses. The stub pattern avoids needing real backends (which may require hardware, network, or root) while still testing the full service lifecycle.

## References

- `tests/manager.nix` — full test implementation
- `artifacts/devlog.md` — "NixOS VM integration test" entry (2026-02-17)
