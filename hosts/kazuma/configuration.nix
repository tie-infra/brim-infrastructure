{
  config,
  lib,
  pkgs,
  ...
}:
let
  multicastDnsPort = 5353; # UDP
  llmnrPort = 5355; # UDP/TCP

  pufferpanelWebPort = 8080;
  pufferpanelSftpPort = 5657;

  # https://satisfactory.wiki.gg/wiki/Dedicated_servers#Port_Forwarding_and_Firewall_Settings
  satisfactoryPort = 7777; # UDP/TCP
  satisfactoryReliablePort = 8888; # UDP/TCP

  rustPort = 28015; # UDP (game), TCP (rcon)
  rustQueryPort = 28016; # UDP
  rustPlusPort = 28082; # TCP

  minecraftPorts = {
    from = 25500;
    to = 25599;
  }; # TCP
in
{
  system.stateVersion = "23.11";

  boot = {
    loader.systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };

    initrd.availableKernelModules = [ "nvme" ];
  };

  environment.machineInfo = {
    chassis = "server";
    location = "Ivan’s homelab";
  };

  profiles.btrfs-erase-your-darlings = {
    enable = true;
    bootDisk = "/dev/disk/by-uuid/1628-65F3";
    rootDisk = "/dev/disk/by-uuid/5104f49c-ff08-49dc-96e4-8fbe00702f0a";
  };

  networking.hostName = "kazuma";

  networking.firewall = {
    allowedUDPPorts = [
      multicastDnsPort
      llmnrPort
      satisfactoryPort
      rustPort
      rustQueryPort
    ];
    allowedTCPPorts = [
      llmnrPort
      pufferpanelWebPort
      pufferpanelSftpPort
      satisfactoryPort
      satisfactoryReliablePort
      rustPort
      rustPlusPort
    ];
    allowedTCPPortRanges = [
      minecraftPorts
    ];
  };

  systemd.network.networks."10-wan" = {
    matchConfig = {
      Name = "enp6s0";
    };
    networkConfig = {
      DHCP = true;
      LLMNR = true;
      MulticastDNS = true;
    };
    linkConfig = {
      RequiredForOnline = "routable";
    };
  };

  services.fstrim.enable = true;

  services.pufferpanel = {
    enable = true;
    extraGroups = [
      config.users.groups.podman.name
    ];
    extraPackages = with pkgs; [
      bash
      rust-server.oxide
      eco-server
      satisfactory-server
      javaWrappers.java8
      javaWrappers.java17
      javaWrappers.java21
      javaWrappers.java25
    ];
    environment = {
      PUFFER_WEB_HOST = ":${toString pufferpanelWebPort}";
      PUFFER_DAEMON_SFTP_HOST = ":${toString pufferpanelSftpPort}";
      PUFFER_PANEL_ENABLE = "false";
      PUFFER_TOKEN_PUBLIC = "https://panel.brim.su/auth/publickey";
      PUFFER_DAEMON_AUTH_URL = "https://panel.brim.su/oauth2/token";
      PUFFER_DAEMON_AUTH_CLIENTID = ".node_2";
      # PUFFER_DAEMON_AUTH_CLIENTSECRET is set via environmentFile
      PUFFER_DAEMON_CONSOLE_BUFFER = "1000";
      PUFFER_SECURITY_DISABLEUNSHARE = "true";
    };
    environmentFile = config.sops.secrets."pufferpanel/env".path;
  };

  sops.secrets = {
    "pufferpanel/env" = {
      restartUnits = [ "pufferpanel.service" ];
      sopsFile = ../../secrets/kazuma.sops.yaml;
    };
  };

  systemd.services.pufferpanel.serviceConfig.ProtectKernelTunables = lib.mkForce false;
}
