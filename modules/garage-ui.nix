{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.garage-ui;
  settingsFormat = pkgs.formats.yaml { };
  configFile = settingsFormat.generate "garage-ui.yaml" cfg.settings;
in
{
  options.services.garage-ui = {
    enable = lib.mkEnableOption "Garage UI";

    package = lib.mkPackageOption pkgs "garage-ui" { };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = settingsFormat.type;
        options = {
          server = {
            host = lib.mkOption {
              type = lib.types.str;
              default = "::1";
              description = "Listen address for the Garage UI HTTP server.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = 8080;
              description = "Listen port for the Garage UI HTTP server.";
            };
            environment = lib.mkOption {
              type = lib.types.enum [
                "development"
                "production"
              ];
              default = "production";
              description = "Runtime environment mode.";
            };
          };
          auth.jwt_private_key_path = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/garage-ui/jwt-key.pem";
            description = "Path where Garage UI persists its auto-generated Ed25519 JWT signing key.";
          };
        };
      };
      default = { };
      description = ''
        Garage UI configuration, see <https://github.com/Noooste/garage-ui/blob/main/config.example.yaml> for reference.
        Do not put secrets here; supply them via `adminTokenFile` or `environmentFiles`.
      '';
    };

    adminTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/garage/admin-token";
      description = ''
        Path to a file containing the Garage Admin API token, loaded into the service via systemd credentials (`GARAGE_UI_GARAGE_ADMIN_TOKEN_FILE`).
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Environment files loaded by the `garage-ui` systemd service for additional runtime secrets.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.garage-ui = {
      description = "Garage UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      restartTriggers = [ configFile ];
      environment = {
        CONFIG_FILE = configFile;
      }
      // lib.optionalAttrs (cfg.adminTokenFile != null) {
        GARAGE_UI_GARAGE_ADMIN_TOKEN_FILE = "%d/garage-admin-token";
      };
      serviceConfig = {
        Type = "exec";
        Restart = "on-failure";
        RestartSec = "5s";

        ExecSearchPath = lib.makeBinPath [ cfg.package ];
        ExecStart = "garage-ui -config \${CONFIG_FILE}";

        EnvironmentFile = cfg.environmentFiles;
        LoadCredential = lib.optional (
          cfg.adminTokenFile != null
        ) "garage-admin-token:${cfg.adminTokenFile}";

        StateDirectory = "garage-ui";
        StateDirectoryMode = "0700";

        DynamicUser = true;
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
        UMask = "0077"; # u=rwx,g=,o=
      };
    };
  };
}
