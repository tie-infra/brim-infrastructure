{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-26.05";

    flake-parts.url = "flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    minimal-shell.url = "github:tie-infra/minimal-shell";
    minimal-shell.inputs.nixpkgs-lib.follows = "nixpkgs";

    btrfs-rollback.url = "github:tie-infra/btrfs-rollback";
    btrfs-rollback.inputs.nixpkgs.follows = "nixpkgs";
    btrfs-rollback.inputs.flake-parts.follows = "flake-parts";
    btrfs-rollback.inputs.minimal-shell.follows = "minimal-shell";

    steam-games.url = "github:tie-infra/steam-games";
    steam-games.inputs.nixpkgs.follows = "nixpkgs";
    steam-games.inputs.flake-parts.follows = "flake-parts";
    steam-games.inputs.treefmt-nix.follows = "treefmt-nix";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.minimal-shell.flakeModule

        ./nixpkgs.nix
        ./nixos-system.nix
        ./configurations.nix
      ];

      perSystem.imports = [ ./shell.nix ];

      perSystem.treefmt = {
        projectRootFile = "flake.nix";
        programs.deadnix.enable = true;
        programs.nixfmt.enable = true;
        settings.on-unmatched = "info";
      };
    };
}
