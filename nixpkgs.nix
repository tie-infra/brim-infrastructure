{ inputs, lib, ... }:
{
  perSystem =
    { system, ... }:
    let
      packagesOverlay =
        final: _:
        lib.packagesFromDirectoryRecursive {
          inherit (final) callPackage;
          directory = ./packages;
        };

      nixpkgsArgs = {
        localSystem = {
          inherit system;
        };

        overlays = [
          inputs.btrfs-rollback.overlays.default
          packagesOverlay
          (import ./overlays/zapret/default.nix)
        ];

        config.allowUnfreePredicate = pkg: lib.getName pkg == "outline";
      };

      nixpkgsFun = newArgs: import inputs.nixpkgs (nixpkgsArgs // newArgs);
    in
    {
      _module.args = {
        pkgs = nixpkgsFun { };
      };
    };
}
