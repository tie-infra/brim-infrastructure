{
  lib,
  pkgs,
  ...
}:
let
  webPort = 8080;
  sftpPort = 5657;
in
{
  services.caddy.settings.apps.http.servers.default = {
    routes = [
      {
        match = [
          {
            host = [
              "panel.brim.su"
              "panel.brimworld.online"
            ];
          }
        ];
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:${toString webPort}"; } ];
          }
        ];
      }
    ];
  };

  services.pufferpanel = {
    enable = true;
    extraPackages = with pkgs; [
      bash
      javaWrappers.java8
      javaWrappers.java17
      javaWrappers.java21
      javaWrappers.java25
    ];

    environment = {
      PUFFER_WEB_HOST = ":${toString webPort}";
      PUFFER_PANEL_REGISTRATIONENABLED = "false";
      PUFFER_DAEMON_SFTP_HOST = ":${toString sftpPort}";
      PUFFER_DAEMON_CONSOLE_BUFFER = "1000";
      PUFFER_SECURITY_DISABLEUNSHARE = "true";
    };
  };

  systemd.services.pufferpanel.serviceConfig.ProtectKernelTunables = lib.mkForce false;
}
