{
  config,
  ...
}:
let
  singboxPort = 18443;
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

  services.sing-box = {
    enable = true;
    settings = {
      log = {
        # Temporary, for the relay.brim.su session-drop investigation: at
        # "info" a re-established hysteria2 outbound is not printed at all, so
        # the suspected QUIC reconnect to vpn.brim.su leaves no trace. Restore
        # "info" once the logs are collected; "debug" also records the
        # destination of every relayed connection.
        level = "debug";
      };

      inbounds = [
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
      ];

      route = {
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
}
