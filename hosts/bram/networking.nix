let
  wanInterface = "eth0";

  # Active exit/tunnel IPv4. To fail over after an IP block, swap activeIpv4
  # and spareIpv4 and deploy.
  activeIpv4 = "77.221.155.29";
  spareIpv4 = "217.144.189.29";
  activeIpv6 = "2a01:e5c0:4ce3::2";
in
{
  networking = {
    hostName = "bram";

    firewall = {
      # No inbound VPN ports are opened on bram: bram initiates all tunnels
      # outbound and relies on conntrack for return UDP packets.
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
      filterForward = true;
      extraForwardRules = ''
        iifname "wg0" oifname "${wanInterface}" accept
      '';
    };

    nftables.tables.vpn-nat = {
      family = "inet";
      content = ''
        chain forward-mss {
          type filter hook forward priority mangle; policy accept;
          iifname "wg0" tcp flags syn tcp option maxseg size set rt mtu
          oifname "wg0" tcp flags syn tcp option maxseg size set rt mtu
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          oifname "${wanInterface}" ip saddr 10.66.0.0/24 snat ip to ${activeIpv4}
          oifname "${wanInterface}" ip6 saddr fd66:66::/64 snat ip6 to ${activeIpv6}
        }
      '';
    };
  };

  systemd.network.networks."10-wan" = {
    matchConfig.Name = wanInterface;
    networkConfig = {
      Address = [
        "${activeIpv4}/32"
        "${spareIpv4}/32"
        "${activeIpv6}/48"
      ];
      # Quad9 DNS10 (unsecured / no blocklist) with opportunistic DoT so early
      # boot DNS still works before NTP sync.
      DNS = [
        "9.9.9.10#dns10.quad9.net"
        "149.112.112.10#dns10.quad9.net"
        "2620:fe::10#dns10.quad9.net"
        "2620:fe::fe:10#dns10.quad9.net"
      ];
      DNSOverTLS = "opportunistic";
      IPv6AcceptRA = false;
    };
    routes = [
      {
        Gateway = "10.0.0.1";
        GatewayOnLink = true;
        PreferredSource = activeIpv4;
      }
      {
        Gateway = "2a01:e5c0:4ce3::1";
        GatewayOnLink = true;
      }
    ];
    linkConfig.RequiredForOnline = "routable";
  };

  boot = {
    kernelModules = [ "tcp_bbr" ];
    kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";
    };
  };
}
