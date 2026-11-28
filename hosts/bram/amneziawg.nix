{
  config,
  ...
}:
let
  broomAwgService = config.systemd.services.amneziawg-awg0.name;
  brimAwgService = config.systemd.services.amneziawg-awg1.name;
in
{
  networking.amneziawg.interfaces = {
    awg0 = {
      ips = [ "10.66.0.1/30" ];
      # Aeza's eth0 underlay PMTU is 1452B. With IPv4+UDP (28B), AWG+AEAD (32B),
      # S4=24, and ContentPaddingAddition 0-32 (up to 48B aligned), 1300 leaves
      # 20B headroom below 1452B so large packets never blackhole.
      mtu = 1300;
      # Ephemeral outbound-only UDP port: bram initiates the tunnel toward broom
      # and keeps zero inbound VPN ports open.
      privateKeyFile = config.sops.secrets."amneziawg/broom/private-key".path;
      headerProtectionKeyFile = config.sops.secrets."amneziawg/broom/header-protection-key".path;

      # AWG 3.1 anti-TSPU profile matching broom (no I1..I5 while kernel bug #139
      # is open). Per upstream AWG 3.1 guidance and kernel issue #226, keep
      # S1=S2=S3=S4 and H1..H4 = 1..4 when HeaderProtectionKey and RandomTrailers
      # are enabled; wide H1..H3 ranges cause silent transport packet drops.
      jc = 4;
      jmin = 48;
      jmax = 312;
      s1 = 24;
      s2 = 24;
      s3 = 24;
      s4 = 24;
      h1 = "1";
      h2 = "2";
      h3 = "3";
      h4 = "4";
      contentPaddingAddition = "0-32";
      # Shorter RekeyAfterTime than broom (150-165) ensures bram stays the sole
      # handshake initiator across session rekeys.
      rekeyAfterTime = "90-110";
      randomTrailers = true;
      disableCookies = true;

      peers = [
        {
          publicKey = "8dBtOq2tRr89IWmUkH9Tja7iZeCXZStnDIip4L4alVI=";
          presharedKeyFile = config.sops.secrets."amneziawg/broom/preshared-key".path;
          endpoint = "broom.brim.su:41763";
          persistentKeepalive = "15-20";
          allowedIPs = [ "10.66.0.2/32" ];
        }
      ];
    };

    awg1 = {
      ips = [
        "10.66.1.1/30"
        "fd66:66:1::1/64"
      ];
      # Aeza's IPv6 underlay PMTU is 1452B. With IPv6+UDP (48B), AWG+AEAD (32B),
      # S4=24, and ContentPaddingAddition 0-32 (up to 48B aligned), 1280 fits
      # under 1452B (max 1432B) while meeting IPv6's 1280B minimum MTU.
      mtu = 1280;
      # Ephemeral outbound-only UDP port: bram initiates over clean IPv6 toward
      # brim's passive awg0 responder, keeping zero inbound VPN ports on bram.
      privateKeyFile = config.sops.secrets."amneziawg/brim/private-key".path;
      headerProtectionKeyFile = config.sops.secrets."amneziawg/brim/header-protection-key".path;

      # AWG 3.1 profile matching brim (S1..S4 equal, H1..H4 = 1..4 per issue #226;
      # HeaderProtectionKey encrypts headers on the wire). Shorter RekeyAfterTime
      # than brim (150-165) ensures bram always initiates handshakes and rekeys.
      jc = 5;
      jmin = 52;
      jmax = 296;
      s1 = 24;
      s2 = 24;
      s3 = 24;
      s4 = 24;
      h1 = "1";
      h2 = "2";
      h3 = "3";
      h4 = "4";
      contentPaddingAddition = "0-32";
      rekeyAfterTime = "90-110";
      randomTrailers = true;
      disableCookies = true;

      peers = [
        {
          publicKey = "sZpVV3vdCrbzycxQqawu87A1t1alLPdCuqUj8dze0yg=";
          presharedKeyFile = config.sops.secrets."amneziawg/brim/preshared-key".path;
          endpoint = "[2a00:f440:0:614::11]:43821";
          persistentKeepalive = "15-20";
          allowedIPs = [
            "10.66.1.2/32"
            "fd66:66:1::2/128"
          ];
        }
      ];
    };
  };

  sops.secrets."amneziawg/broom/private-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ broomAwgService ];
  };

  sops.secrets."amneziawg/broom/header-protection-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ broomAwgService ];
  };

  sops.secrets."amneziawg/broom/preshared-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ broomAwgService ];
  };

  sops.secrets."amneziawg/brim/private-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ brimAwgService ];
  };

  sops.secrets."amneziawg/brim/header-protection-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ brimAwgService ];
  };

  sops.secrets."amneziawg/brim/preshared-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ brimAwgService ];
  };
}
