{
  config,
  pkgs,
  ...
}:
let
  websiteHosts = [
    "brim.su"
    "api.brim.su"
    "pubg-wiki.brim.su"
  ];

  s3ApiHost = "s3.brim.su";
  s3WebHost = "web.brim.su";
  uiHost = "garage.brim.su";

  hostAddress = "[2a00:f440:0:614::11]";

  garageS3ApiPort = 3900;
  garageRpcPort = 3901;
  garageS3WebPort = 3902;
  garageAdminPort = 3903;

  garageS3Region = "garage";

  garageWebuiPort = 3919;
in
{
  services.caddy.settings.apps.http.servers.default = {
    routes = [
      {
        match = [ { host = [ uiHost ]; } ];
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [
              {
                dial = "localhost:${toString garageWebuiPort}";
              }
            ];
          }
        ];
      }
      {
        match = [
          {
            host = [
              s3ApiHost
              ("*." + s3ApiHost)
            ];
          }
        ];
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [
              {
                dial = "localhost:${toString garageS3ApiPort}";
              }
            ];
          }
        ];
      }
      {
        match = [
          {
            host = websiteHosts ++ [
              ("*." + s3WebHost)
            ];
          }
        ];
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [
              {
                dial = "localhost:${toString garageS3WebPort}";
              }
            ];
          }
        ];
      }
      {
        match = [ { host = [ "assets.brim.su" ]; } ];
        handle = [
          {
            handler = "static_response";
            status_code = 301; # Moved Permanently
            headers.Location = [ "https://brim.su/assets/" ];
          }
        ];
      }
    ];
  };

  services.garage-webui = {
    enable = true;
  };

  systemd.services.garage-webui = {
    restartTriggers = [
      config.environment.etc."garage.toml".source
    ];
    environment = {
      HOST = "[::1]";
      PORT = toString garageWebuiPort;
      CONFIG_PATH = pkgs.emptyFile; # do not depend on /etc/garage.toml
      API_BASE_URL = "http://localhost:${toString garageAdminPort}";
      S3_ENDPOINT_URL = "http://localhost:${toString garageS3ApiPort}";
      S3_REGION = garageS3Region;
      # API_ADMIN_KEY is set in EnvironmentFile
    };
    serviceConfig = {
      EnvironmentFile = [
        config.sops.templates."garage-webui.env".path
      ];
    };
  };

  services.garage = {
    enable = true;
    settings = {
      metadata_dir = "meta";
      data_dir = "data";

      allow_world_readable_secrets = true;

      rpc_bind_addr = "[::]:${toString garageRpcPort}";
      rpc_public_addr = "${hostAddress}:${toString garageRpcPort}";
      rpc_secret_file = config.sops.secrets."garage/rpc-secret".path;

      replication_factor = 1;

      s3_api = {
        s3_region = garageS3Region;
        api_bind_addr = "[::]:${toString garageS3ApiPort}";
        root_domain = "." + s3ApiHost;
      };

      s3_web = {
        bind_addr = "[::]:${toString garageS3WebPort}";
        root_domain = "." + s3WebHost;
      };

      admin = {
        api_bind_addr = "[::]:${toString garageAdminPort}";
        admin_token_file = config.sops.secrets."garage/admin-token".path;
        metrics_token_file = config.sops.secrets."garage/metrics-token".path;
      };
    };
  };

  users = {
    users.garage = {
      isSystemUser = true;
      group = config.users.groups.garage.name;
    };
    groups.garage = { };
  };

  systemd.services.garage = {
    serviceConfig = {
      User = config.users.users.garage.name;
      Group = config.users.groups.garage.name;
      SupplementaryGroups = [
        config.users.groups.keys.name
      ];
    };
  };

  sops.templates."garage-webui.env" = {
    content = ''
      AUTH_USER_PASS=${config.sops.placeholder."garage-webui/user-pass"}
      API_ADMIN_KEY=${config.sops.placeholder."garage/admin-token"}
    '';
    restartUnits = [
      config.systemd.services.garage-webui.name
    ];
  };

  sops.secrets."garage-webui/user-pass" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [ config.systemd.services.garage-webui.name ];
  };

  sops.secrets."garage/rpc-secret" = {
    mode = "0440"; # u=r,g=r,o=
    group = config.users.groups.garage.name;
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [ config.systemd.services.garage.name ];
  };

  sops.secrets."garage/admin-token" = {
    mode = "0440"; # u=r,g=r,o=
    group = config.users.groups.garage.name;
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [
      config.systemd.services.garage.name
      config.systemd.services.garage-webui.name
    ];
  };

  sops.secrets."garage/metrics-token" = {
    mode = "0440"; # u=r,g=r,o=
    group = config.users.groups.garage.name;
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [ config.systemd.services.garage.name ];
  };
}
