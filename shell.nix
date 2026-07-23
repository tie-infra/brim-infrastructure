{ pkgs, ... }:
{
  minimalShells.direnv = with pkgs; [
    nixfmt
    sops
    ssh-to-age
    go-task
  ];
}
