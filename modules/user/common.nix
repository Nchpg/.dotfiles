{ lib, pkgs-stable, pkgs-unstable, ... }:
{
  home.packages =
    (with pkgs-stable; [
      tree
      curl
      wget
      ncdu
      discord
      btop
      bat
      pavucontrol
    ])
    ++
    (with pkgs-unstable; [

    ]);
}

