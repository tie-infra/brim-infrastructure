{ nixosWithSystem, ... }:
{
  flake.nixosConfigurations = {
    brim = nixosWithSystem "x86_64-linux" [
      ./hosts/brim/configuration.nix
      ./hosts/brim/networking.nix
      ./hosts/brim/amneziawg.nix
      ./hosts/brim/caddy.nix
      ./hosts/brim/caddy-routes.nix
      ./hosts/brim/outline.nix
      ./hosts/brim/garage.nix
      ./hosts/brim/pufferpanel.nix
      ./hosts/brim/syncthing.nix
      ./hosts/brim/sing-box.nix
    ];

    bram = nixosWithSystem "x86_64-linux" [
      ./hosts/bram/configuration.nix
      ./hosts/bram/networking.nix
      ./hosts/bram/amneziawg.nix
    ];
  };
}
