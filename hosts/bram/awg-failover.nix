{
  config,
  ...
}:
let
  failoverService = config.systemd.services.awg-failover.name;
in
{
  services.awg-failover = {
    enable = true;
    interface = "awg0";
    wanInterface = "eth0";
    gateway = "10.0.0.1";
    fwMark = "0x6600";
    routeTable = 110;
    policyRulePriority = 100;
    candidates = [
      "217.144.189.29"
      "77.221.155.29"
    ];
    peerPublicKey = "8dBtOq2tRr89IWmUkH9Tja7iZeCXZStnDIip4L4alVI=";
    peerEndpoint = "broom.brim.su:41763";
    peerWanIp = "195.170.194.163";
    tunnelLocalIp = "10.66.0.1";
    tunnelPeerIp = "10.66.0.2";
    snatSubnet = "10.66.0.0/23";
    nftTable = "inet vpn-nat";
    nftChain = "postrouting-v4";

    telegramBotTokenFile = config.sops.secrets."awg-failover/telegram-bot-token".path;
    telegramChatIdFile = config.sops.secrets."awg-failover/telegram-chat-id".path;
    # Uncomment once awg-failover/cheburcheck-api-token is added to secrets/bram.sops.yaml:
    # cheburcheckApiTokenFile = config.sops.secrets."awg-failover/cheburcheck-api-token".path;
  };

  sops.secrets."awg-failover/telegram-bot-token" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ failoverService ];
  };

  sops.secrets."awg-failover/telegram-chat-id" = {
    sopsFile = ../../secrets/bram.sops.yaml;
    restartUnits = [ failoverService ];
  };
}
