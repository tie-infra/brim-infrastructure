{ nixosWithSystem, ... }:
{
  flake.nixosConfigurations = {
    bootstrap-x86-64 = nixosWithSystem "x86_64-linux" [ ./hosts/bootstrap/configuration.nix ];
    akane = nixosWithSystem "x86_64-linux" [
      ./hosts/akane/configuration.nix
      ./hosts/akane/networking.nix
      ./hosts/akane/caddy.nix
      ./hosts/akane/mumble-server.nix
      ./hosts/akane/xray.nix
      ./hosts/akane/mcp.nix
    ];
    brim = nixosWithSystem "x86_64-linux" [
      ./hosts/brim/configuration.nix
      ./hosts/brim/networking.nix
      ./hosts/brim/caddy.nix
      ./hosts/brim/caddy-routes.nix
      ./hosts/brim/outline.nix
      ./hosts/brim/garage.nix
      ./hosts/brim/pufferpanel.nix
      ./hosts/brim/syncthing.nix
      ./hosts/brim/sing-box.nix
    ];
    kazuma = nixosWithSystem "x86_64-linux" [
      ./hosts/kazuma/configuration.nix
      ./hosts/kazuma/docker.nix
    ];
    saitama = nixosWithSystem "x86_64-linux" [
      ./hosts/saitama/configuration.nix
      ./hosts/saitama/caddy.nix
    ];
    falcon = nixosWithSystem "x86_64-linux" [
      ./hosts/falcon/configuration.nix
    ];
  };
}
