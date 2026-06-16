let
  wireguardPort = 51337;
in
{ config, pkgs, ... }:
{
  system.stateVersion = "24.05";

  boot = {
    loader.systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };

    kernelParams = [ "nomodeset" ]; # for KVM Console

    initrd.availableKernelModules = [ "nvme" ];
  };

  environment.machineInfo = {
    chassis = "server";
    location = "Falkenstein";
  };

  environment.systemPackages = with pkgs; [
    wireguard-tools
    traceroute
    tcpdump
    ndisc6
    iperf3
  ];

  profiles.btrfs-erase-your-darlings = {
    enable = true;
    bootDisk = "/dev/disk/by-uuid/2EBA-AC04";
    rootDisk = "/dev/disk/by-uuid/84b3349c-3c87-4d95-b4de-1c1a646fce09";
  };

  networking.hostName = "falcon";
  networking = {
    firewall = {
      enable = true;
      logReversePathDrops = true;
      allowedUDPPorts = [ wireguardPort ];
    };
    # systemd-networkd masquerading is not flexible enough for our setup.
    # See https://github.com/systemd/systemd/issues/8040
    nat = {
      enable = true;
      externalInterface = "enp9s0";
      internalIPs = [ "172.16.0.0/12" ];
    };
    mssfix = {
      enable = true;
    };
  };

  systemd.network.config = {
    networkConfig = {
      IPv4Forwarding = true;
      IPv6Forwarding = true;
    };
  };

  # Available subnets:
  # • 2a01:4f8:222:fe00::/56
  # • 2a01:4f8:222:1618::/64
  # • 213.133.111.103/32
  # • 172.16.0.0/12
  systemd.network = {
    networks = {
      "10-wan" = {
        matchConfig = {
          Name = "enp9s0";
        };
        addresses = [
          {
            Address = "2a01:4f8:222:1618::1/64";
            AddPrefixRoute = false;
            DuplicateAddressDetection = "none";
          }
          {
            Address = "213.133.111.103/27";
            AddPrefixRoute = false;
          }
        ];
        routes = [
          {
            Gateway = "fe80::1";
            GatewayOnLink = true;
          }
          {
            Gateway = "213.133.111.97";
            GatewayOnLink = true;
          }
          {
            Type = "unreachable";
            Destination = "192.168.0.0/16";
          }
        ];
        networkConfig = {
          DHCP = false;
          IPv6AcceptRA = false;
          LLMNR = false;
          MulticastDNS = false;
          DNS = [
            "2606:4700:4700::1111"
            "2606:4700:4700::1001"
            "1.1.1.1"
            "1.0.0.1"
          ];
        };
        linkConfig = {
          RequiredForOnline = "routable";
        };
      };
      "20-wg" = {
        matchConfig = {
          Name = "wg-lan";
        };
        linkConfig = {
          RequiredForOnline = "carrier:routable";
        };
      };
    };
    netdevs = {
      "10-wg" = {
        netdevConfig = {
          Name = "wg-lan";
          Kind = "wireguard";
        };
        wireguardConfig = {
          ListenPort = wireguardPort;
          PrivateKeyFile = config.sops.secrets."wireguard/pk.txt".path;
        };
        wireguardPeers = [
          {
            AllowedIPs = [
              "2a01:4f8:222:fee0::/60"
              # NB 28d = 00011100b = 1Ch, damn IPv4 subnets are not easy.
              # That said, we can use 28–31 for a /16 subnet.
              "172.28.0.0/14"
            ];
            RouteTable = "main";
            PublicKey = "gvAPp/g475vG9Jpj9b4rdPKPwhIKvuxynuw8EffMrGk=";
            Endpoint = "akane.tie.rip:${toString wireguardPort}";
            PresharedKeyFile = config.sops.secrets."wireguard/psk.txt".path;
            PersistentKeepalive = 30;
          }
        ];
      };
    };
  };

  services.fstrim.enable = true;

  systemd.services.systemd-networkd = {
    serviceConfig = {
      SupplementaryGroups = [ config.users.groups.keys.name ];
    };
  };

  sops.secrets = {
    "wireguard/pk.txt" = {
      mode = "0440";
      group = config.users.groups.systemd-network.name;
      reloadUnits = [ config.systemd.services.systemd-networkd.name ];
      sopsFile = ../../secrets/wireguard-pk-falcon.sops.yaml;
    };
    "wireguard/psk.txt" = {
      mode = "0440";
      group = config.users.groups.systemd-network.name;
      reloadUnits = [ config.systemd.services.systemd-networkd.name ];
      sopsFile = ../../secrets/wireguard-psk.sops.yaml;
    };
  };
}
