{
  lib,
  pkgs,
  config,
  ...
}:
let
  sshHostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  sshAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIPgvPYPtXXqGGerR7k+tbrIG2fCzp3R8ox7mkKRIdEu actions@github.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAiAKU7x1o6NPI/7AqwCaC8edvl80//2LgyVSV/3tIfb mr.trubach@icloud.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx5SqHCvHuGCt7o+8dVu9sZiXeHP95ROuDGF9+DufCe dev@brim.su"
  ];
in
{
  environment = {
    systemPackages = with pkgs; [
      ripgrep
      fd
      file
      tree
      htop
      btop
      duf
      dool
      vim
      rcon
      websocat
      mc
      tmux
    ];
    shellAliases = {
      lsd = "lsblk --nodeps --output=MODEL,SERIAL,SIZE,NAME,TYPE,TRAN,FSTYPE --sort=NAME";
      ip4 = "ip -4";
      ip6 = "ip -6";
    };
    variables = {
      # Most terminals are dark, but ip from iproute2 assumes otherwise.
      # See also https://unix.stackexchange.com/a/245568
      COLORFGBG = ";0";
    };
  };

  # Use systemd in initrd during boot.
  boot.initrd.systemd.enable = true;

  # Use /etc overlayfs instead of generating it with Perl script.
  system.etc.overlay.enable = true;

  # Do not generate documentation for NixOS modules.
  documentation.nixos.enable = false;

  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # For some workloads, zram provides significant RAM usage savings with
  # otherwise negligible performance impact.
  zramSwap.enable = true;

  time.timeZone = "Europe/Moscow";

  networking = {
    # Enable systemd-networkd for network configuration management instead of
    # ad-hoc NixOS networking infrastructure.
    useNetworkd = true;

    # Use nftables instead of legacy iptables for firewall.
    nftables.enable = true;

    # Disables DHCP on `en*` and `eth*` interfaces.
    # See https://github.com/NixOS/nixpkgs/blob/2920b6fc16a9ed5d51429e94238b28306ceda79e/nixos/modules/tasks/network-interfaces-systemd.nix#L49-L56
    #
    # Network configuration is host-specific.
    useDHCP = lib.mkDefault false;

    # By default, NixOS logs refused TCP connections to the kernel log (see
    # dmesg). Since we are on the wild Internet, we likely get a lot of these.
    firewall.logRefusedConnections = lib.mkDefault false;
  };

  systemd.network.config.networkConfig = {
    # Enable traffic meters on all interfaces.
    # https://www.freedesktop.org/software/systemd/man/networkd.conf.html#SpeedMeter=
    SpeedMeter = true;
    # Enable IPv6 privacy extensions for all interfaces by default and prefer
    # temporary addresses. See also net.ipv6.conf.all.use_tempaddr.
    # https://www.freedesktop.org/software/systemd/man/networkd.conf.html#IPv6PrivacyExtensions=
    IPv6PrivacyExtensions = true;
  };

  # While polkit is a bit controversial, systemd is deeply integrated with it.
  # Having it enabled makes interactions with systemctl and other commands more
  # convenient.
  security.polkit.enable = true;

  # Disable mutable users (i.e. useradd and other commands). Define a single
  # nixos user that we use for administrative tasks.
  users = {
    mutableUsers = false;
    users.nixos = {
      uid = 1000;
      isNormalUser = true;
      extraGroups = with config.users.groups; [
        wheel.name
        disk.name
      ];
      openssh.authorizedKeys.keys = sshAuthorizedKeys;
    };
  };

  services = {
    # Automatically log in as nixos user from terminals without unnecessary
    # password prompts. Password prompt is a nuisance in this case since an
    # attacker would likely have a physical access to the server, making it
    # trivial to bypass the prompt.
    getty.autologinUser = config.users.users.nixos.name;

    # Enable systemd-networkd for local DNS resolution and cache.
    resolved = {
      enable = true;
      settings.Resolve.FallbackDNS = [ ];
    };

    # Enable OpenSSH sever that uses systemd socket activation instead of
    # running all the time.
    openssh = {
      enable = true;
      # Disable automatic host key generation on startup. This ensures that SSH
      # host keys are not overwritten should the filesystem misbehave. Instead,
      # we configure host keys explicitly.
      hostKeys = lib.mkDefault [ ];
      settings = {
        HostKey = lib.mkDefault sshHostKeyPath;
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        LoginGraceTime = "15s";
      };
    };

    # Keep service package selections independent of host configuration.
    caddy.package = pkgs.caddy-with-plugins;
    garage.package = pkgs.garage_2;
    mysql.package = pkgs.mariadb_1011;
    postgresql.package = pkgs.postgresql_16;
  };
}
