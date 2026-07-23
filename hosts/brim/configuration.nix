{
  pkgs,
  ...
}:
{
  system.stateVersion = "23.11";

  i18n.defaultLocale = "ru_RU.UTF-8";

  boot = {
    loader.systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };

    initrd.availableKernelModules = [
      "mpt3sas"
      "i7core_edac"
    ];
  };

  profiles.btrfs-erase-your-darlings = {
    enable = true;
    bootDisk = "/dev/disk/by-uuid/9F30-7212";
    rootDisk = "/dev/disk/by-uuid/96448376-c96b-4fa0-adcb-65dee46427c0";
  };

  services = {
    mysql = {
      enable = true;
      package = pkgs.mariadb_1011;
    };

    postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
    };
  };
}
