{
  config,
  ...
}:
let
  singboxPort = 18443;

  # Caddy already listens on :443 for both TCP and UDP (it serves HTTP/3), so
  # the Hysteria2 inbound cannot take 443/UDP without disabling h3 there.
  hysteriaPort = 8443;
in
{
  services.caddy.settings.apps.http.servers.default = {
    routes = [
      {
        match = [ { host = [ "relay.brim.su" ]; } ];
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:${toString singboxPort}"; } ];
          }
        ];
      }
    ];
  };

  networking.firewall.allowedUDPPorts = [ hysteriaPort ];

  services.sing-box = {
    enable = true;
    settings = {
      log = {
        level = "info";
      };

      inbounds = [
        # Clients reach the relay over Hysteria2. VLESS+WS+TLS below stopped
        # connecting from the user's ISP in September 2026 — the TLS-in-TLS
        # pattern is filtered, while the relay itself stayed reachable (a
        # WebSocket upgrade from outside Russia still answered 101 on every
        # attempt, over both IPv4 and IPv6). Hysteria2 moves that leg to UDP
        # with salamander obfuscation; it is RU→RU traffic, so the
        # cross-border throttling of high-bitrate UDP does not apply to it.
        {
          type = "hysteria2";
          tag = "hy2-in";
          listen = "::";
          listen_port = hysteriaPort;
          users = [
            {
              name = "pc";
              password = {
                _secret = config.sops.secrets."hysteria2/pc-auth".path;
              };
            }
          ];
          obfs = {
            type = "salamander";
            password = {
              _secret = config.sops.secrets."hysteria2/inbound-obfs".path;
            };
          };
          # Deliberately no up_mbps/down_mbps: leaving them unset selects BBR
          # instead of Brutal. Brutal ignores packet loss by design, which is
          # the wrong trade on a domestic link that measures clean anyway.
          tls = {
            enabled = true;
            server_name = "relay.brim.su";
            # Caddy holds the *.brim.su wildcard but keeps it in its own state
            # directory, unreadable by the sing-box user, so this obtains a
            # separate certificate over DNS-01 with the token Caddy already
            # uses. The two never collide: the challenge records differ
            # (_acme-challenge.brim.su vs _acme-challenge.relay.brim.su).
            #
            # Inline ACME is deprecated in sing-box 1.14 and removed in 1.16 —
            # migrate to a certificate provider before that bump:
            # https://sing-box.sagernet.org/migration/#migrate-inline-acme-to-certificate-provider
            acme = {
              domain = [ "relay.brim.su" ];
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

        # Kept as a fallback: it costs nothing while idle, and if Hysteria2 is
        # ever filtered too, clients can switch back without a deploy.
        {
          type = "vless";
          tag = "vless-ws-in";
          listen = "::1";
          listen_port = singboxPort;
          users = [
            {
              uuid = "1ea52fe2-2e51-4951-9b0c-4f8c16e47890";
            }
          ];
          transport = {
            type = "ws";
            path = "/relay";
          };
        }
      ];

      outbounds = [
        {
          type = "hysteria2";
          tag = "hy2-out";
          server = "vpn.brim.su";
          server_port = 443;
          password = {
            _secret = config.sops.secrets."hysteria2/moscow-auth".path;
          };
          obfs = {
            type = "salamander";
            password = {
              _secret = config.sops.secrets."hysteria2/obfs-password".path;
            };
          };
          tls = {
            enabled = true;
            server_name = "vpn.brim.su";
          };
        }
        {
          type = "direct";
          tag = "direct";
        }
      ];

      route = {
        rules = [
          # Russian services refuse or blackhole foreign and datacenter
          # addresses, so relaying them abroad and back only costs latency —
          # or fails outright. pass.yandex.ru is the clearest case: from the
          # exit node it times out identically over IPv4, over IPv6 and
          # through WARP, which is why it cannot be fixed by routing on that
          # side. This host has a Russian address and reaches them directly.
          {
            domain_suffix = [
              "2gis.ru"
              "avito.ru"
              "gosuslugi.ru"
              "kinopoisk.ru"
              "mail.ru"
              "ok.ru"
              "ozon.ru"
              "rutube.ru"
              "sberbank.ru"
              "userapi.com"
              "vk.com"
              "vk.ru"
              "wildberries.ru"
              "ya.ru"
              "yandex.net"
              "yandex.ru"
              "yastatic.net"
            ];
            outbound = "direct";
          }
        ];
        final = "hy2-out";
      };
    };
  };

  sops.secrets."hysteria2/moscow-auth" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [
      config.systemd.services.sing-box.name
    ];
  };

  sops.secrets."hysteria2/obfs-password" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [
      config.systemd.services.sing-box.name
    ];
  };

  sops.secrets."hysteria2/pc-auth" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [
      config.systemd.services.sing-box.name
    ];
  };

  sops.secrets."hysteria2/inbound-obfs" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [
      config.systemd.services.sing-box.name
    ];
  };

  # Declared with its own sopsFile in caddy.nix; this only adds sing-box to the
  # units restarted when the token rotates.
  sops.secrets."cloudflare/dns-api-token".restartUnits = [
    config.systemd.services.sing-box.name
  ];
}
