{ config, lib, pkgs-stable, pkgs-unstable, ... }:

{
  config = lib.mkDefault {
    nixpkgs.config.allowUnfree = true;

    userSettings = {
      defaultPkgs = pkgs-stable;
      
      stylix = {
        enable = true;
        # Pas de `theme` : suit le thème système (systemSettings.stylix.theme),
        # donc bascule avec `theme dark|light`.
      };

      vim.enable = true;

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmail = "nathan.champagne@epita.fr";
      };

      shell = {
        zsh.enable = true;
        bash.enable = true;
        fish.enable = true;
      };
    };
  };
}