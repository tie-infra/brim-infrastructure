{ inputs, lib, ... }:
{
  perSystem =
    { system, ... }:
    let
      nixpkgsArgs = {
        localSystem = {
          inherit system;
        };

        overlays = [
          inputs.steam-games.overlays.default
          inputs.btrfs-rollback.overlays.default
          (import ./overlays/java-wrappers.nix)
          (import ./overlays/mlspp.nix)
          (import ./overlays/libdave.nix)
          (import ./overlays/mumble-discord-bridge.nix)
          (import ./overlays/zapret/default.nix)
          (import ./overlays/sonarr/default.nix)
          (import ./overlays/markdown-to-confluence.nix)
          (import ./overlays/mcp-atlassian.nix)
          (import ./overlays/caddy-with-plugins.nix)
          (import ./overlays/pufferpanel/default.nix)
        ];

        config.allowUnfreePredicate =
          let
            allowUnfree = {
              steamworks-sdk-redist = true;
              satisfactory-server = true;
              rust-server = true;
              palworld-server = true;
              eco-server = true;
              outline = true;
            };
          in
          pkg: builtins.hasAttr (lib.getName pkg) allowUnfree;

        # For rust-server.oxide.
        config.allowInsecurePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "dotnet-runtime"
            "dotnet-sdk"
          ]
          && lib.versions.major (lib.getVersion pkg) == "7";
      };

      nixpkgsFun = newArgs: import inputs.nixpkgs (nixpkgsArgs // newArgs);
    in
    {
      _module.args = {
        pkgs = nixpkgsFun { };
        pkgsCross = {
          x86-64 = nixpkgsFun { crossSystem.config = "x86_64-unknown-linux-gnu"; };
        };
      };
    };
}
