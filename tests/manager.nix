# NixOS VM test for the remote sandbox manager
#
# Exercises the full API lifecycle: list, create, stop, delete.
# Uses a stub claude-sandbox (sleep) to avoid needing the real backend.
{ self }:

{
  name = "manager";

  nodes.server = { pkgs, ... }: {
    imports = [ self.nixosModules.manager ];

    services.claude-sandbox-manager = {
      enable = true;
      sandboxPackages = [
        (pkgs.writeShellScriptBin "claude-sandbox" ''
          echo "Stub sandbox: $*"
          sleep 300
        '')
      ];
    };

    # tmux needs a real shell; the system user defaults to nologin
    systemd.services.claude-sandbox-manager.environment.SHELL =
      "${pkgs.bash}/bin/bash";

    environment.systemPackages = with pkgs; [ curl jq ];
  };

  testScript = ''
    import json

    server.wait_for_unit("claude-sandbox-manager")
    server.wait_for_open_port(3000)

    # 1. Empty sandbox list
    result = server.succeed("curl -sf http://localhost:3000/api/sandboxes")
    assert json.loads(result) == [], f"Expected empty list, got: {result}"

    # 2. System metrics returns valid JSON
    server.succeed("curl -sf http://localhost:3000/api/metrics/system | jq .")

    # 3. Create a sandbox
    server.succeed("mkdir -p /tmp/test-project")
    result = server.succeed(
        "curl -sf -X POST -H 'Content-Type: application/json' "
        "-d '{\"name\":\"test\",\"backend\":\"bubblewrap\",\"project_dir\":\"/tmp/test-project\"}' "
        "http://localhost:3000/api/sandboxes"
    )
    sandbox = json.loads(result)
    sandbox_id = sandbox["id"]
    assert sandbox["name"] == "test"
    assert sandbox["backend"] == "bubblewrap"
    assert sandbox["status"] == "running"

    # 4. List should have one entry
    result = server.succeed("curl -sf http://localhost:3000/api/sandboxes")
    sandboxes = json.loads(result)
    assert len(sandboxes) == 1, f"Expected 1 sandbox, got {len(sandboxes)}"

    # 5. Stop the sandbox (returns 204)
    server.succeed(
        f"curl -sf -X POST http://localhost:3000/api/sandboxes/{sandbox_id}/stop"
    )

    # 6. Verify stopped
    result = server.succeed(
        f"curl -sf http://localhost:3000/api/sandboxes/{sandbox_id}"
    )
    sandbox = json.loads(result)
    assert sandbox["status"] == "stopped", f"Expected stopped, got: {sandbox['status']}"

    # 7. Delete the sandbox (returns 204)
    server.succeed(
        f"curl -sf -X DELETE http://localhost:3000/api/sandboxes/{sandbox_id}"
    )

    # 8. List should be empty again
    result = server.succeed("curl -sf http://localhost:3000/api/sandboxes")
    assert json.loads(result) == [], f"Expected empty list after delete, got: {result}"

    # 9. State file exists and is valid JSON
    server.succeed("jq . /var/lib/claude-manager/state.json")
  '';
}
