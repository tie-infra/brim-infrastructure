{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.garage;
  settingsFormat = pkgs.formats.toml { };
  configFile = settingsFormat.generate "garage.toml" cfg.settings;
in
{
  options.services.garage = {
    enable = lib.mkEnableOption "Garage Object Storage (S3 compatible)";

    package = lib.mkPackageOption pkgs "garage" { };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = settingsFormat.type;
      };
      description = ''
        Garage configuration, see <https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/> for reference.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."garage.toml" = {
      source = configFile;
    };

    environment.systemPackages = [
      cfg.package
    ];

    systemd.services.garage = {
      description = "Garage Object Storage (S3 compatible)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      restartTriggers = [ configFile ];
      environment = {
        RUST_LOG = "garage=info";
        RUST_BACKTRACE = "1";
      };
      serviceConfig = {
        Type = "exec";
        Restart = "on-failure";

        ExecSearchPath = lib.makeBinPath [ cfg.package ];
        ExecStart = "garage server";

        WorkingDirectory = "%S/garage";

        StateDirectory = "garage";
        StateDirectoryMode = "0750"; # u=rwx,g=rx,o=

        DynamicUser = true;
        ProtectHome = true;
        NoNewPrivileges = true;

        # https://garagehq.deuxfleurs.fr/documentation/cookbook/systemd/
        LimitNOFILE = 42000;
      };
    };
  };
}
