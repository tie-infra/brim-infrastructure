{
  inputs,
  lib,
  withSystem,
  ...
}:
let
  # See https://dataswamp.org/~solene/2022-07-20-nixos-flakes-command-sync-with-system.html
  nixpkgsFlakeRegistryModule = {
    nix.registry.nixpkgs.flake = inputs.nixpkgs;
  };

  baseModules = [
    nixpkgsFlakeRegistryModule
    inputs.sops-nix.nixosModules.sops
    ./modules/sops.nix
    ./modules/nix-flakes.nix
    ./modules/base-configuration.nix
    ./modules/btrfs-erase-your-darlings.nix
    ./modules/trust-admins.nix
    ./modules/outline.nix
    ./modules/garage.nix
    ./modules/garage-webui.nix
    ./modules/zapret/nfqws.nix
    ./modules/zapret/nfqws-systemd.nix
    { inherit disabledModules; }
  ];

  disabledModules = [
    "services/networking/zapret.nix"
    "services/web-apps/outline.nix"
    "services/web-servers/garage.nix"
  ];

  nixosSystem =
    pkgs: hostConfigurations:
    lib.nixosSystem {
      modules =
        hostConfigurations
        ++ baseModules
        ++ [
          # Avoid re-evaluating Nixpkgs.
          inputs.nixpkgs.nixosModules.readOnlyPkgs
          { nixpkgs.pkgs = pkgs; }
        ];
    };
in
{
  _module.args.nixosWithSystem =
    system: hostConfigurations: withSystem system ({ pkgs, ... }: nixosSystem pkgs hostConfigurations);
}
