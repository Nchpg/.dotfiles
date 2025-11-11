{ lib, pkgs-stable, pkgs-unstable, stylix,... }:
{
  home.packages =
    (with pkgs-stable; [
      discord
      pavucontrol
    ])
    ++
    (with pkgs-unstable; [

    ]);

    programs.neovim = {
      enable = true;
    };

    stylix.targets.neovim.enable = true;
}

