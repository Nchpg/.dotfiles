{ lib, pkgs-stable, pkgs-unstable, stylix,... }:
{
  home.packages =
    (with pkgs-stable; [
      curl
      wget
      ncdu
      discord
      pavucontrol
      eza
      fd
      ripgrep
      lazydocker
      lazysql
      delta
      broot
    ])
    ++
    (with pkgs-unstable; [

    ]);

    programs.yazi = {
      enable = true;
    };
    programs.bat = {
      enable = true;
    };
    programs.btop = {
      enable = true;
    };
    programs.lazygit = {
      enable = true;
    };
    programs.feh = {
      enable = true;
    };
    programs.neovim = {
      enable = true;
    };

    stylix.targets.yazi.enable = true;
    stylix.targets.bat.enable = true;
    stylix.targets.btop.enable = true;
    stylix.targets.fzf.enable = true;
    stylix.targets.lazygit.enable = true;
    stylix.targets.feh.enable = true;
    stylix.targets.neovim.enable = true;
  
}

