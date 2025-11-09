{ lib, pkgs-stable, pkgs-unstable, stylix,... }:
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
      eza
      fd
      yazi
      ripgrep
      lazygit
      lazydocker
      lazysql
    ])
    ++
    (with pkgs-unstable; [

    ]);

    stylix.targets.yazi.enable = true;
    stylix.targets.bat.enable = true;
    stylix.targets.btop.enable = true;
    stylix.targets.fzf.enable = true;
    stylix.targets.lazygit.enable = true;
  
}

