# Not a module.
{ lib, pkgs }:
let
  inherit (lib)
    attrValues
    concatMap
    drop
    literalExpression
    mkOption
    optionals
    ;
  inherit (lib.types)
    attrsOf
    bool
    int
    listOf
    nullOr
    oneOf
    package
    str
    submodule
    ;
  inherit (lib.cli)
    toCommandLineGNU
    ;

  argType = nullOr (oneOf [
    bool
    int
    str
    (listOf str)
  ]);

  canExecute = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;

  generateConfigFile =
    name: configArgs:
    pkgs.callPackage (
      { runCommand, python3 }:
      runCommand name
        {
          inherit configArgs;
          __structuredAttrs = true;
          nativeBuildInputs = [ python3 ];
          pythonScript = ''
            import pathlib
            import shlex
            import sys

            out = sys.argv[1]
            config = shlex.join(sys.argv[2:])

            out_path = pathlib.Path(out)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(config)
          '';
        }
        ''
          python3 -c "$pythonScript" "$out" "''${configArgs[@]}"
        ''
    ) { };

  profileModule =
    {
      config,
      name,
      ...
    }:
    {
      options = {
        enable = mkOption {
          type = bool;
          default = true;
          description = ''
            Whether to enable this desync profile.
          '';
        };
        settings = mkOption {
          type = submodule { freeformType = attrsOf argType; };
          default = { };
          description = ''
            Declarative DPI desync profile configuration.
          '';
        };
        args = mkOption {
          type = listOf str;
          internal = true;
          readOnly = true;
        };
      };
      config.args = [
        "--new"
        "--comment=${name}"
      ]
      ++ toCommandLineGNU { } config.settings;
    };

in
{
  instanceModule =
    {
      config,
      name,
      # passed via _module.args
      service,
      ...
    }:
    {
      options = {
        enable = mkOption {
          type = bool;
          default = true;
          description = ''
            Whether to enable this ${service.name} instance.
          '';
        };
        check = mkOption {
          type = bool;
          default = canExecute;
          defaultText = literalExpression ''
            stdenv.buildPlatform.canExecute stdenv.hostPlatform
          '';
          description = ''
            Whether to check the configuration with --dry-run flag at build time.
          '';
        };
        settings = mkOption {
          type = submodule { freeformType = attrsOf argType; };
          default = { };
          description = ''
            Declarative configuration for ${service.name} service.

            For more details, see
            <https://github.com/bol-van/zapret/blob/master/docs/readme.en.md#${service.name}>
          '';
        };
        profiles = mkOption {
          type = attrsOf (submodule profileModule);
          default = { };
          description = ''
            DPI desync profiles.
          '';
        };
        configFile = mkOption {
          type = package;
          internal = true;
          readOnly = true;
        };
      };
      config.configFile =
        let
          desyncArgs = concatMap (x: optionals x.enable x.args) (attrValues config.profiles);
          args =
            toCommandLineGNU { } config.settings
            # Initial profile is implicit so remove first --new flag.
            ++ drop 1 desyncArgs;
          configFile = generateConfigFile "${service.name}-${name}.config" args;
        in
        if config.check then
          configFile.overrideAttrs {
            dryRun =
              pkgs.runCommand "${service.name}-${name}-check-config"
                {
                  __structuredAttrs = true;
                  nativeBuildInputs = [ service.package ];
                  executable = service.name;
                  configFile = configFile.overrideAttrs (oldAttrs: {
                    name = "dry-run-" + oldAttrs.name;
                    configArgs = [ "--dry-run" ] ++ oldAttrs.configArgs;
                  });
                }
                ''
                  "$executable" @"$configFile"
                  mkdir -p "$out"
                '';
          }
        else
          configFile;
    };
}
