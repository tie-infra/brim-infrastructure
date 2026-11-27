{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking.amneziawg;
  settingsFormat = pkgs.formats.json { };

  boolToOnOff =
    value:
    if value == null then
      null
    else if value then
      "on"
    else
      "off";

  peerSubmodule = lib.types.submodule {
    options = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "Base64-encoded public key of the peer.";
      };
      presharedKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file containing the optional preshared key.";
      };
      allowedIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "CIDR ranges routed to and accepted from this peer.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "broom.brim.su:41763";
        description = "Optional peer host:port endpoint for initiating outbound handshakes.";
      };
      persistentKeepalive = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "15-20";
        description = "Optional AWG 3.1 persistent keepalive interval or range in seconds.";
      };
    };
  };

  policyRuleSubmodule = lib.types.submodule {
    options = {
      from = lib.mkOption {
        type = lib.types.str;
        description = "Source prefix matched by the routing policy rule.";
      };
      table = lib.mkOption {
        type = lib.types.str;
        description = "Routing table name or number looked up when the rule matches.";
      };
      priority = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Optional explicit rule priority.";
      };
    };
  };

  interfaceSubmodule = lib.types.submodule {
    options = {
      ips = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "IPv4 and/or IPv6 CIDR addresses assigned to the interface.";
      };
      mtu = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional interface MTU.";
      };
      listenPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Optional UDP listen port; omit for an ephemeral outbound-only initiator port.";
      };
      fwMark = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional netfilter fwmark applied to encrypted tunnel packets.";
      };
      privateKeyFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime path to a file containing the interface private key (never stored in the Nix store).";
      };
      headerProtectionKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file containing the AWG 3.1 HeaderProtectionKey (requires S1..S4 >= 12).";
      };
      table = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional routing table for `routes`.";
      };
      routes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra destination prefixes routed out of this interface.";
      };
      routingPolicyRules = lib.mkOption {
        type = lib.types.listOf policyRuleSubmodule;
        default = [ ];
        description = "Optional IP policy routing rules associated with this interface.";
      };
      jc = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG junk packet count before handshake initiation.";
      };
      jmin = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG minimum junk packet size in bytes.";
      };
      jmax = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG maximum junk packet size in bytes.";
      };
      s1 = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG handshake initiation random prefix padding size (>= 12 with HeaderProtectionKey).";
      };
      s2 = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG handshake response random prefix padding size (>= 12 with HeaderProtectionKey).";
      };
      s3 = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG cookie reply random prefix padding size (>= 12 with HeaderProtectionKey).";
      };
      s4 = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG transport data random prefix padding size (>= 12 with HeaderProtectionKey).";
      };
      h1 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "AWG handshake initiation header value or range (min-max).";
      };
      h2 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "AWG handshake response header value or range (min-max).";
      };
      h3 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "AWG cookie reply header value or range (min-max).";
      };
      h4 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "AWG transport data header value or range (min-max).";
      };
      contentPaddingAddition = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "0-48";
        description = "AWG 3.1 random transport content padding size or range in bytes.";
      };
      rekeyAfterTime = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "90-110";
        description = "AWG 3.1 session rekey time or range in seconds.";
      };
      rekeyTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "AWG 3.1 handshake rekey retry timeout or range in seconds.";
      };
      rejectAfterTime = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "AWG 3.1 session reject age or range in seconds.";
      };
      keepaliveTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "35-45";
        description = "AWG 3.1 passive keepalive timeout or range in seconds.";
      };
      maxHandshakeAttempts = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "AWG 3.1 maximum handshake attempts.";
      };
      randomTrailers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Enable AWG 3.1 random trailers on packets (must match on both peers).";
      };
      disableCookies = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Disable cookie reply packets in AWG 3.1.";
      };
      peers = lib.mkOption {
        type = lib.types.listOf peerSubmodule;
        default = [ ];
        description = "Peers configured on this AmneziaWG interface.";
      };
    };
  };

  mkInterfaceService =
    name: iface:
    let
      indexedPeers = lib.imap0 (i: peer: {
        inherit i peer;
      }) iface.peers;

      configData = {
        inherit name;
        inherit (iface)
          ips
          mtu
          listenPort
          fwMark
          table
          routes
          routingPolicyRules
          ;
        privateKeyCredential = "private-key";
        headerProtectionKeyCredential =
          if iface.headerProtectionKeyFile != null then "header-protection-key" else null;
        awg = {
          inherit (iface)
            jc
            jmin
            jmax
            s1
            s2
            s3
            s4
            h1
            h2
            h3
            h4
            ;
          content-padding-addition = iface.contentPaddingAddition;
          rekey-after-time = iface.rekeyAfterTime;
          rekey-timeout = iface.rekeyTimeout;
          reject-after-time = iface.rejectAfterTime;
          keepalive-timeout = iface.keepaliveTimeout;
          max-handshake-attempts = iface.maxHandshakeAttempts;
          random-trailers = boolToOnOff iface.randomTrailers;
          disable-cookies = boolToOnOff iface.disableCookies;
        };
        peers = map (
          { i, peer }:
          {
            inherit (peer)
              publicKey
              allowedIPs
              endpoint
              persistentKeepalive
              ;
            presharedKeyCredential =
              if peer.presharedKeyFile != null then "preshared-key-${toString i}" else null;
          }
        ) indexedPeers;
      };

      configFile = settingsFormat.generate "amneziawg-${name}.json" configData;

      credentials = [
        "private-key:${iface.privateKeyFile}"
      ]
      ++ lib.optional (
        iface.headerProtectionKeyFile != null
      ) "header-protection-key:${iface.headerProtectionKeyFile}"
      ++ lib.concatMap (
        { i, peer }:
        lib.optional (peer.presharedKeyFile != null) "preshared-key-${toString i}:${peer.presharedKeyFile}"
      ) indexedPeers;
    in
    {
      description = "AmneziaWG interface ${name}";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "nss-lookup.target"
      ];
      wants = [
        "network-online.target"
        "nss-lookup.target"
      ];
      restartTriggers = [ configFile ];
      environment.CONFIG_FILE = configFile;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecSearchPath = lib.makeBinPath [
          pkgs.amneziawg-configure
          cfg.package
          pkgs.iproute2
        ];
        ExecStart = "amneziawg-configure up \${CONFIG_FILE}";
        ExecStop = "amneziawg-configure down \${CONFIG_FILE}";

        LoadCredential = credentials;

        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
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
in
{
  options.networking.amneziawg = {
    package = lib.mkPackageOption pkgs "amneziawg-tools" { };

    interfaces = lib.mkOption {
      type = lib.types.attrsOf interfaceSubmodule;
      default = { };
      description = "Declarative AmneziaWG 3.1 kernel interfaces.";
    };
  };

  config = lib.mkIf (cfg.interfaces != { }) {
    boot.extraModulePackages = [ config.boot.kernelPackages.amneziawg ];
    boot.kernelModules = [ "amneziawg" ];

    environment.systemPackages = [ cfg.package ];

    systemd.network.networks = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "90-amneziawg-${name}" {
        matchConfig.Name = name;
        linkConfig.Unmanaged = true;
      }
    ) cfg.interfaces;

    systemd.services = lib.mapAttrs' (
      name: iface: lib.nameValuePair "amneziawg-${name}" (mkInterfaceService name iface)
    ) cfg.interfaces;
  };
}
