{ pkgs, ... }:
{
  minimalShells.direnv = with pkgs; [
    broom-deploy
    nixfmt
    sops
    ssh-to-age
    go-task
  ];
}
