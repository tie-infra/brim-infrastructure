{
  config,
  ...
}:
let
  awgPort = 43821;
  bramIpv6 = "2a01:e5c0:4ce3::2";
  awgService = config.systemd.services.amneziawg-awg0.name;
in
{
  # Accept inbound AWG 3.1 handshakes strictly from bram's Amsterdam IPv6.
  networking.firewall.extraInputRules = ''
    ip6 saddr ${bramIpv6} udp dport ${toString awgPort} accept
  '';

  # Replies arriving on awg0 come from arbitrary internet sources, while the
  # default route out of awg0 lives in policy table 100 (matched on source IP,
  # which nftables' strict rpfilter fib lookup does not pass). Allow decrypted
  # packets arriving on awg0 addressed to brim's tunnel IPs while keeping
  # strict reverse-path filtering intact on enp3s0f0.
  networking.firewall.extraReversePathFilterRules = ''
    iifname "awg0" ip daddr 10.66.1.2 accept
    iifname "awg0" ip6 daddr fd66:66:1::2 accept
  '';

  networking.amneziawg.interfaces.awg0 = {
    ips = [
      "10.66.1.2/30"
      "fd66:66:1::2/64"
    ];
    # Outer transport runs over IPv6 (40-byte header) with S4=24 and up to 48B
    # content padding, so 1320 keeps every encrypted datagram under 1500B.
    mtu = 1320;
    listenPort = awgPort;
    privateKeyFile = config.sops.secrets."amneziawg/bram/private-key".path;
    headerProtectionKeyFile = config.sops.secrets."amneziawg/bram/header-protection-key".path;

    # Keep brim's main routing table untouched so Caddy, Garage, Outline,
    # PufferPanel, Minecraft, Syncthing, and nfqws never traverse the tunnel.
    # Only sockets explicitly bound to awg0's tunnel IPs (sing-box bram-awg)
    # look up table 100.
    table = "100";
    routes = [
      "0.0.0.0/0"
      "::/0"
    ];
    routingPolicyRules = [
      {
        from = "10.66.1.2/32";
        table = "100";
        priority = 1000;
      }
      {
        from = "fd66:66:1::2/128";
        table = "100";
        priority = 1000;
      }
    ];

    # Independent AWG 3.1 anti-TSPU profile for bram <-> brim (no I1..I5 while
    # upstream kernel bug #139 remains open). Longer RekeyAfterTime and
    # KeepaliveTimeout than bram ensure bram always initiates handshakes.
    jc = 5;
    jmin = 52;
    jmax = 296;
    s1 = 44;
    s2 = 72;
    s3 = 32;
    s4 = 24;
    h1 = "312450100-358912400";
    h2 = "841205300-894120500";
    h3 = "1412890100-1465120300";
    h4 = "1945120300-1998450200";
    contentPaddingAddition = "0-48";
    rekeyAfterTime = "150-165";
    keepaliveTimeout = "35-45";
    randomTrailers = true;
    disableCookies = true;

    # Passive responder: deliberately no endpoint and no persistentKeepalive.
    peers = [
      {
        publicKey = "cUoSH02VOjVUishvEW+i5wa2YaPjtMnueg2R2jscY18=";
        presharedKeyFile = config.sops.secrets."amneziawg/bram/preshared-key".path;
        allowedIPs = [
          "0.0.0.0/0"
          "::/0"
        ];
      }
    ];
  };

  sops.secrets."amneziawg/bram/private-key" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [ awgService ];
  };

  sops.secrets."amneziawg/bram/header-protection-key" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [ awgService ];
  };

  sops.secrets."amneziawg/bram/preshared-key" = {
    sopsFile = ../../secrets/brim.sops.yaml;
    restartUnits = [ awgService ];
  };
}
