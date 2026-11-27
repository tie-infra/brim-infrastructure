{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.happ-sub;
  settingsFormat = pkgs.formats.json { };

  userSubmodule = lib.types.submodule {
    options = {
      hy2PasswordFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime path to the user's Hysteria 2 password file.";
      };
      vlessUuidFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime path to the user's VLESS UUID file.";
      };
    };
  };

  configData = {
    inherit (cfg)
      host
      port
      serverHost
      hy2Port
      hy2Sni
      vlessPort
      realitySni
      realityPublicKey
      realityShortId
      profileTitle
      updateInterval
      ;
    marzbanSecretCredential = "marzban-jwt-secret";
    hy2ObfsCredential = "hy2-obfs";
    users = lib.mapAttrs (name: _: {
      hy2PasswordCredential = "user-${name}-hy2";
      vlessUuidCredential = "user-${name}-vless";
    }) cfg.users;
  };

  configFile = settingsFormat.generate "happ-sub.json" configData;

  credentials = [
    "marzban-jwt-secret:${cfg.marzbanSecretFile}"
    "hy2-obfs:${cfg.hy2ObfsFile}"
  ]
  ++ lib.concatLists (
    lib.mapAttrsToList (name: u: [
      "user-${name}-hy2:${u.hy2PasswordFile}"
      "user-${name}-vless:${u.vlessUuidFile}"
    ]) cfg.users
  );
in
{
  options.services.happ-sub = {
    enable = lib.mkEnableOption "Marzban-compatible Happ VPN subscription server";

    package = lib.mkPackageOption pkgs "happ-sub" { };

    host = lib.mkOption {
      type = lib.types.str;
      default = "::1";
      description = "Loopback bind address for the subscription HTTP server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18000;
      description = "Listen port for the subscription HTTP server.";
    };

    serverHost = lib.mkOption {
      type = lib.types.str;
      example = "relay.brim.su";
      description = "Public VPN relay hostname emitted in generated client URIs.";
    };

    hy2Port = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Hysteria 2 UDP port emitted in generated client URIs.";
    };

    hy2Sni = lib.mkOption {
      type = lib.types.str;
      example = "relay.brim.su";
      description = "Hysteria 2 TLS SNI emitted in generated client URIs.";
    };

    vlessPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "VLESS Reality TCP port emitted in generated client URIs.";
    };

    realitySni = lib.mkOption {
      type = lib.types.str;
      example = "brim.su";
      description = "VLESS Reality SNI emitted in generated client URIs.";
    };

    realityPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "VLESS Reality x25519 public key emitted in generated client URIs.";
    };

    realityShortId = lib.mkOption {
      type = lib.types.str;
      description = "VLESS Reality short ID emitted in generated client URIs.";
    };

    profileTitle = lib.mkOption {
      type = lib.types.str;
      default = "🦊 VPN";
      description = "Human-readable subscription title encoded into the Happ Profile-Title header.";
    };

    updateInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Subscription refresh interval in hours (`Profile-Update-Interval`).";
    };

    marzbanSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path to the `MARZBAN_JWT_SECRET` used to verify legacy subscription tokens.";
    };

    hy2ObfsFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path to the Hysteria 2 salamander obfuscation password.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userSubmodule;
      default = { };
      description = "Allowed subscription users and their credential file paths.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.happ-sub = {
      description = "Marzban-compatible Happ VPN subscription server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      restartTriggers = [ configFile ];
      environment.CONFIG_FILE = configFile;
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";

        ExecSearchPath = lib.makeBinPath [ cfg.package ];
        ExecStart = "happ-sub \${CONFIG_FILE}";

        LoadCredential = credentials;

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
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
        UMask = "0077";
      };
    };
  };
}
