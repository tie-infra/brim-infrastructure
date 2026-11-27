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
      mtu = 1340;
      # Ephemeral outbound-only UDP port: bram initiates the tunnel toward broom
      # and keeps zero inbound VPN ports open.
      privateKeyFile = config.sops.secrets."amneziawg/broom/private-key".path;
      headerProtectionKeyFile = config.sops.secrets."amneziawg/broom/header-protection-key".path;

      # AWG 3.1 anti-TSPU profile matching broom. I1..I5 CPS parameters are
      # intentionally omitted while upstream kernel bug #139 (teardown oops) is open.
      jc = 4;
      jmin = 48;
      jmax = 312;
      s1 = 38;
      s2 = 64;
      s3 = 28;
      s4 = 24;
      h1 = "184231040-219845120";
      h2 = "612940210-658412900";
      h3 = "1194823100-1248192400";
      h4 = "1742918400-1798412900";
      contentPaddingAddition = "0-48";
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
      # Matches brim's outer IPv6 MTU budget (40B IPv6 header + S4=24 + up to 48B padding).
      mtu = 1320;
      # Ephemeral outbound-only UDP port: bram initiates over clean IPv6 toward
      # brim's passive awg0 responder, keeping zero inbound VPN ports on bram.
      privateKeyFile = config.sops.secrets."amneziawg/brim/private-key".path;
      headerProtectionKeyFile = config.sops.secrets."amneziawg/brim/header-protection-key".path;

      # Independent AWG 3.1 anti-TSPU profile matching brim (no I1..I5 while
      # upstream kernel bug #139 remains open). Shorter RekeyAfterTime than brim
      # (150-165) ensures bram always initiates handshakes and rekeys.
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
