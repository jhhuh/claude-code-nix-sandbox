# NixOS module for the Claude Sandbox Manager service
{ config, lib, pkgs, ... }:

let
  cfg = config.services.claude-sandbox-manager;
in
{
  options.services.claude-sandbox-manager = {
    enable = lib.mkEnableOption "Claude Sandbox Manager web dashboard";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:3000";
      description = "Address and port for the manager to listen on.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/claude-manager";
      description = "Directory for persistent state (state.json).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "claude-manager";
      description = "System user to run the manager as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "claude-manager";
      description = "System group to run the manager as.";
    };

    sandboxPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Sandbox backend packages to put on the manager's PATH.";
    };

    containerSudoers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add a sudoers rule for passwordless claude-sandbox-container.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
    };
    users.groups.${cfg.group} = { };

    systemd.services.claude-sandbox-manager = {
      description = "Claude Sandbox Manager";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        MANAGER_LISTEN = cfg.listenAddress;
        MANAGER_STATE_DIR = cfg.stateDir;
      };

      path = cfg.sandboxPackages;

      serviceConfig = {
        ExecStart = "${pkgs.callPackage ../../nix/manager/package.nix { }}/bin/claude-sandbox-manager";
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "claude-manager";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    security.sudo.extraRules = lib.mkIf cfg.containerSudoers [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "/run/current-system/sw/bin/claude-sandbox-container";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
