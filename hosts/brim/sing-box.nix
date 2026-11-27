{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Caddy owns :443 TCP+UDP (HTTP/3), so both sing-box client inbounds share
  # port 8443: Hysteria 2 on 8443/UDP and VLESS Reality on 8443/TCP.
  relayHost = "relay.brim.su";
  hysteriaPort = 8443;
  vlessRealityPort = 8443;
  realitySni = "brim.su";
  realityPublicKey = "sNPEeXUVrsBMiSRrPWxuEB92YiinA7lGwB7gRXohKjQ";
  realityShortId = "9eaaca28ab83067c";

  # Legacy Happ subscription endpoint: https://vpn.brim.su:8000/sub/<token>
  subPublicPort = 8000;
  subBackendPort = 18000;

  # Tunnel IPv4/IPv6 assigned to brim's awg0 (routed via policy table 100 -> bram).
  awgIpv4 = "10.66.1.2";
  awgIpv6 = "fd66:66:1::2";

  vpnUsers = [
    "brim"
    "krudanny"
    "wenerra"
    "ojegova"
    "Serg_Denisoff"
    "leoden7"
    "dtv46"
  ];

  ruDomainSuffixes = [
    "ru"
    "su"
    "xn--p1ai"
    "2gis.com"
    "avito.st"
    "brimworld.online"
    "ozonusercontent.com"
    "userapi.com"
    "vk.com"
    "vk.me"
    "vkuseraudio.net"
    "vkuserlive.net"
    "vkuservideo.net"
    "wbstatic.net"
    "yandex.net"
    "yastatic.net"
  ];

  singBoxService = config.systemd.services.sing-box.name;
  happSubService = config.systemd.services.happ-sub.name;
  userRestartUnits = [
    singBoxService
    happSubService
  ];

  mkUserSecrets =
    user:
    lib.listToAttrs [
      {
        name = "sing-box/users/${user}/hy2-password";
        value = {
          sopsFile = ../../secrets/brim.sops.yaml;
          restartUnits = userRestartUnits;
        };
      }
      {
        name = "sing-box/users/${user}/vless-uuid";
        value = {
          sopsFile = ../../secrets/brim.sops.yaml;
          restartUnits = userRestartUnits;
        };
      }
    ];
in
{
  networking.firewall = {
    allowedTCPPorts = [
      vlessRealityPort
      subPublicPort
    ];
    allowedUDPPorts = [
      hysteriaPort
      subPublicPort
    ];
  };

  # Serve legacy Happ subscription URLs on https://vpn.brim.su:8000/sub/<token>
  # using Caddy's existing *.brim.su wildcard certificate.
  services.caddy.settings.apps.http.servers.happ_sub = {
    listen = [ ":${toString subPublicPort}" ];
    routes = [
      {
        match = [
          {
            host = [ "vpn.brim.su" ];
            path = [ "/sub/*" ];
          }
        ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:${toString subBackendPort}"; } ];
          }
        ];
      }
      {
        handle = [
          {
            handler = "static_response";
            status_code = 404;
          }
        ];
      }
    ];
  };

  services.happ-sub = {
    enable = true;
    host = "::1";
    port = subBackendPort;
    serverHost = relayHost;
    hy2Port = hysteriaPort;
    hy2Sni = relayHost;
    vlessPort = vlessRealityPort;
    inherit
      realitySni
      realityPublicKey
      realityShortId
      ;
    marzbanSecretFile = config.sops.secrets."happ-sub/marzban-jwt-secret".path;
    hy2ObfsFile = config.sops.secrets."sing-box/hy2-obfs".path;
    users = lib.genAttrs vpnUsers (user: {
      hy2PasswordFile = config.sops.secrets."sing-box/users/${user}/hy2-password".path;
      vlessUuidFile = config.sops.secrets."sing-box/users/${user}/vless-uuid".path;
    });
  };

  services.sing-box = {
    enable = true;
    settings = {
      log = {
        level = "info";
      };

      dns = {
        servers = [
          # Resolve foreign domains through Quad9 DNS10 over the Amsterdam AWG
          # tunnel so clients receive clean, non-localized A and AAAA answers.
          {
            type = "tls";
            tag = "quad9-abroad";
            server = "9.9.9.10";
            tls = {
              enabled = true;
              server_name = "dns10.quad9.net";
            };
            detour = "bram-awg";
          }
          # Resolve Russian domains via brim's domestic Moscow DNS directly.
          {
            type = "udp";
            tag = "ru-local";
            server = "93.95.97.2";
          }
        ];
        rules = [
          {
            domain_suffix = ruDomainSuffixes;
            server = "ru-local";
          }
        ];
        final = "quad9-abroad";
        strategy = "prefer_ipv6";
      };

      inbounds = [
        # Primary mobile/desktop transport: Hysteria 2 (UDP + salamander obfs)
        # on domestic RU -> brim leg, leaving congestion control on BBR.
        {
          type = "hysteria2";
          tag = "hy2-in";
          listen = "::";
          listen_port = hysteriaPort;
          users = map (user: {
            name = user;
            password = {
              _secret = config.sops.secrets."sing-box/users/${user}/hy2-password".path;
            };
          }) vpnUsers;
          obfs = {
            type = "salamander";
            password = {
              _secret = config.sops.secrets."sing-box/hy2-obfs".path;
            };
          };
          tls = {
            enabled = true;
            server_name = relayHost;
            # Inline ACME is deprecated in sing-box 1.14 and removed in 1.16 —
            # migrate to a certificate provider before that bump:
            # https://sing-box.sagernet.org/migration/#migrate-inline-acme-to-certificate-provider
            acme = {
              domain = [ relayHost ];
              email = "dev@brim.su";
              dns01_challenge = {
                provider = "cloudflare";
                api_token = {
                  _secret = config.sops.secrets."cloudflare/dns-api-token".path;
                };
              };
            };
          };
        }

        # TCP fallback: VLESS + XTLS Vision + Reality handshaking against
        # local Caddy on 127.0.0.1:443 (valid TLS 1.3 cert for brim.su on the
        # exact same IP, zero latency, no SNI/IP mismatch).
        {
          type = "vless";
          tag = "vless-reality-in";
          listen = "::";
          listen_port = vlessRealityPort;
          users = map (user: {
            name = user;
            uuid = {
              _secret = config.sops.secrets."sing-box/users/${user}/vless-uuid".path;
            };
            flow = "xtls-rprx-vision";
          }) vpnUsers;
          tls = {
            enabled = true;
            server_name = realitySni;
            reality = {
              enabled = true;
              handshake = {
                server = "127.0.0.1";
                server_port = 443;
              };
              private_key = {
                _secret = config.sops.secrets."sing-box/reality-private-key".path;
              };
              short_id = [ realityShortId ];
            };
          };
        }
      ];

      outbounds = [
        # Foreign exit: bind sockets to brim's awg0 IPv4/IPv6 so policy table
        # 100 routes them through the reversed AWG 3.1 tunnel to bram (clean
        # Amsterdam IPv4 + IPv6).
        {
          type = "direct";
          tag = "bram-awg";
          inet4_bind_address = awgIpv4;
          inet6_bind_address = awgIpv6;
          bind_address_no_port = true;
        }
        # Domestic exit: Russian destinations stay directly on Moscow enp3s0f0.
        {
          type = "direct";
          tag = "direct";
        }
      ];

      route = {
        rule_set = [
          {
            type = "local";
            tag = "geoip-ru";
            format = "binary";
            path = "${pkgs.sing-geoip}/share/sing-box/rule-set/geoip-ru.srs";
          }
        ];
        rules = [
          {
            action = "sniff";
          }
          # Prevent relayed VPN clients from reaching loopback or private
          # backend services hosted on brim or inside tunnel subnets.
          {
            ip_is_private = true;
            action = "reject";
          }
          {
            domain_suffix = ruDomainSuffixes;
            outbound = "direct";
          }
          {
            rule_set = [ "geoip-ru" ];
            outbound = "direct";
          }
        ];
        final = "bram-awg";
        default_domain_resolver = {
          server = "quad9-abroad";
          strategy = "prefer_ipv6";
        };
      };
    };
  };

  systemd.services.sing-box = {
    after = [ config.systemd.services.amneziawg-awg0.name ];
    wants = [ config.systemd.services.amneziawg-awg0.name ];
  };

  sops.secrets = lib.mkMerge (
    [
      {
        "happ-sub/marzban-jwt-secret" = {
          sopsFile = ../../secrets/brim.sops.yaml;
          restartUnits = [ happSubService ];
        };
        "sing-box/hy2-obfs" = {
          sopsFile = ../../secrets/brim.sops.yaml;
          restartUnits = userRestartUnits;
        };
        "sing-box/reality-private-key" = {
          sopsFile = ../../secrets/brim.sops.yaml;
          restartUnits = [ singBoxService ];
        };
        # Declared with its own sopsFile in caddy.nix; this only adds
        # sing-box to the units restarted when the token rotates.
        "cloudflare/dns-api-token".restartUnits = [ singBoxService ];
      }
    ]
    ++ map mkUserSecrets vpnUsers
  );
}
