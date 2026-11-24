{
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  system.stateVersion = "26.05";

  # Aeza provisions bram with a persistent ext4 /etc (including
  # /etc/ssh/ssh_host_ed25519_key); modules/base-configuration.nix enables
  # overlay /etc for ephemeral btrfs roots, which hides /etc on live switch.
  system.etc.overlay.enable = lib.mkForce false;

  boot = {
    initrd.availableKernelModules = [
      "ata_piix"
      "ahci"
      "sd_mod"
      "sr_mod"
      "nvme"
    ];
    kernelParams = [
      "console=ttyS0,115200n8"
      "net.ifnames=0"
      "biosdevname=0"
    ];
    loader = {
      timeout = 1;
      efi.canTouchEfiVariables = false;
      grub = {
        enable = true;
        devices = [ "/dev/vda" ];
        efiSupport = true;
        efiInstallAsRemovable = true;
        configurationLimit = 5;
      };
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
    };
  };

  hardware.enableRedistributableFirmware = false;
  services.qemuGuest.enable = true;
  nix.settings.auto-optimise-store = true;
}
