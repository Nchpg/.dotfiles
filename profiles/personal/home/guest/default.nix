{
  lib,
  pkgs-stable,
  pkgs-unstable,
  ...
}:

{
  config = lib.mkDefault {

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
        # Pas de `theme` : suit le thème système (systemSettings.stylix.theme),
        # donc bascule avec `theme dark|light`.
      };

      vim = {
        enable = true;
      };

      git = {
        enable = true;
      };

      firefox = {
        enable = true;
      };

      vscode = {
        enable = true;
        pkgs = pkgs-unstable;
      };

      shell = {
        zsh = {
          enable = true;
        };
        bash = {
          enable = true;
        };
        default = "zsh";
      };

      terminal = {
        kitty = {
          enable = true;
        };
        foot = {
          enable = false;
        };
        alacritty = {
          enable = true;
          shell = "bash";
        };
        default = "kitty";
      };
    };
  };
}
