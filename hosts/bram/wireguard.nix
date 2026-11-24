{
  config,
  pkgs,
  ...
}:
{
  environment.systemPackages = [
    pkgs.wireguard-tools
  ];

  systemd.network = {
    netdevs."50-wg0" = {
      netdevConfig = {
        Kind = "wireguard";
        Name = "wg0";
        MTUBytes = "1380";
      };
      wireguardConfig = {
        # No ListenPort: bind an ephemeral UDP port and keep all inbound UDP
        # ports closed in the firewall.
        PrivateKeyFile = config.sops.secrets."wireguard/private-key".path;
      };
      wireguardPeers = [
        {
          # broom (home OpenWrt router)
          PublicKey = "QWw4jFuPZvMmq7jF13JxlFAzQBhS7iEx+0wVkdMiC3E=";
          AllowedIPs = [
            "10.66.0.2/32"
          ];
          Endpoint = "broom.brim.su:43917";
          PersistentKeepalive = 15;
        }
      ];
    };

    networks."50-wg0" = {
      matchConfig.Name = "wg0";
      networkConfig = {
        Address = [
          "10.66.0.1/24"
          "fd66:66::1/64"
        ];
        ConfigureWithoutCarrier = true;
      };
      linkConfig.RequiredForOnline = "no";
    };
  };

  sops.secrets."wireguard/private-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    owner = "systemd-network";
    group = "systemd-network";
    mode = "0400";
    restartUnits = [ "systemd-networkd.service" ];
  };
}
