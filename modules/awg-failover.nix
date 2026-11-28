{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.awg-failover;
  settingsFormat = pkgs.formats.json { };

  configData = {
    inherit (cfg)
      interface
      wanInterface
      gateway
      fwMark
      routeTable
      policyRulePriority
      candidates
      peerPublicKey
      peerEndpoint
      peerWanIp
      tunnelLocalIp
      tunnelPeerIp
      snatSubnet
      nftTable
      nftChain
      wanProbeTargets
      checkIntervalSeconds
      failureThreshold
      handshakeMaxAgeSeconds
      cooldownSeconds
      recoveryWaitSeconds
      cheburcheckBaseUrl
      cheburcheckTimeoutSeconds
      ;
    stateFile = "/var/lib/awg-failover/state.json";
    telegramBotTokenCredential =
      if cfg.telegramBotTokenFile != null then "telegram-bot-token" else null;
    telegramChatIdCredential = if cfg.telegramChatIdFile != null then "telegram-chat-id" else null;
    cheburcheckApiTokenCredential =
      if cfg.cheburcheckApiTokenFile != null then "cheburcheck-api-token" else null;
  };

  configFile = settingsFormat.generate "awg-failover.json" configData;

  credentials =
    lib.optional (cfg.telegramBotTokenFile != null) "telegram-bot-token:${cfg.telegramBotTokenFile}"
    ++ lib.optional (cfg.telegramChatIdFile != null) "telegram-chat-id:${cfg.telegramChatIdFile}"
    ++ lib.optional (
      cfg.cheburcheckApiTokenFile != null
    ) "cheburcheck-api-token:${cfg.cheburcheckApiTokenFile}";

  awgUnit = "amneziawg-${cfg.interface}.service";
in
{
  options.services.awg-failover = {
    enable = lib.mkEnableOption "event-driven IPv4 TSPU failover for an AmneziaWG interface";

    package = lib.mkPackageOption pkgs "awg-failover" { };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "awg0";
      description = "AmneziaWG interface name monitored for IPv4 failover.";
    };

    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "WAN interface carrying candidate IPv4 addresses.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      description = "On-link IPv4 default gateway for the WAN interface.";
    };

    fwMark = lib.mkOption {
      type = lib.types.str;
      default = "0x6600";
      description = "FwMark configured on the AmneziaWG interface for outer packet policy routing.";
    };

    routeTable = lib.mkOption {
      type = lib.types.ints.positive;
      default = 110;
      description = "IPv4 routing table number used to steer marked outer AmneziaWG packets.";
    };

    policyRulePriority = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 100;
      description = "Priority of the ip rule matching fwMark to routeTable.";
    };

    candidates = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      description = "Ordered list of candidate IPv4 addresses configured on wanInterface.";
    };

    peerPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Base64 public key of the remote AmneziaWG peer.";
    };

    peerEndpoint = lib.mkOption {
      type = lib.types.str;
      description = "Remote AmneziaWG peer host:port endpoint re-applied on switch to clear cached src4.";
    };

    peerWanIp = lib.mkOption {
      type = lib.types.str;
      description = "Remote peer WAN IPv4 address used for lightweight ICMP reachability probes on failure.";
    };

    tunnelLocalIp = lib.mkOption {
      type = lib.types.str;
      description = "Local IPv4 address inside the AmneziaWG tunnel.";
    };

    tunnelPeerIp = lib.mkOption {
      type = lib.types.str;
      description = "Remote peer IPv4 address inside the AmneziaWG tunnel pinged for health checks.";
    };

    snatSubnet = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 CIDR subnet SNATed to the active IPv4 address in nftables.";
    };

    nftTable = lib.mkOption {
      type = lib.types.str;
      default = "inet vpn-nat";
      description = "nftables family and table name containing nftChain.";
    };

    nftChain = lib.mkOption {
      type = lib.types.str;
      default = "postrouting-v4";
      description = "Dedicated nftables NAT chain flushed and updated with the active IPv4 SNAT rule.";
    };

    wanProbeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "9.9.9.10"
        "1.1.1.1"
      ];
      description = "External IPv4 targets used to confirm local WAN health before diagnosing a block.";
    };

    checkIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Interval in seconds between in-tunnel health checks.";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Consecutive health-check failures required before probing external targets and switching.";
    };

    handshakeMaxAgeSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = "Informational handshake freshness threshold in seconds.";
    };

    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Minimum delay in seconds between automatic switches or repeated alerts.";
    };

    recoveryWaitSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Seconds to wait for in-tunnel ping recovery after switching IPv4.";
    };

    cheburcheckBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://cheburcheck.ru/api/v1";
      description = "Base URL of the Cheburcheck v1 API.";
    };

    cheburcheckTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 35;
      description = "Timeout in seconds for Cheburcheck SSE scanner streams.";
    };

    telegramBotTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime path to a file containing the Telegram bot token.";
    };

    telegramChatIdFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime path to a file containing the Telegram chat ID.";
    };

    cheburcheckApiTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional runtime path to a file containing the Cheburcheck API token for /probe/<id> SSE scans.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = configFile;
      description = "Generated non-secret JSON configuration file for CLI tools and systemd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.services.awg-failover = {
      description = "AmneziaWG IPv4 TSPU failover daemon (${cfg.interface})";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "nss-lookup.target"
        "nftables.service"
        awgUnit
      ];
      wants = [
        "network-online.target"
        "nss-lookup.target"
        awgUnit
      ];
      path = [
        pkgs.amneziawg-tools
        pkgs.iproute2
        pkgs.iputils
        pkgs.nftables
      ];
      restartTriggers = [ configFile ];
      environment.CONFIG_FILE = configFile;
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";

        ExecSearchPath = lib.makeBinPath [ cfg.package ];
        ExecStart = "awg-failover daemon \${CONFIG_FILE}";

        LoadCredential = credentials;
        StateDirectory = "awg-failover";
        StateDirectoryMode = "0700";

        DynamicUser = true;
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
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
