{
  config,
  ...
}:
let
  awgService = config.systemd.services.amneziawg-awg0.name;
in
{
  networking.amneziawg.interfaces.awg0 = {
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

  sops.secrets."amneziawg/broom/private-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ awgService ];
  };

  sops.secrets."amneziawg/broom/header-protection-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ awgService ];
  };

  sops.secrets."amneziawg/broom/preshared-key" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ awgService ];
  };
}
