{ config, lib, pkgs-stable, pkgs-unstable, ... }:

{
  imports = (lib.optional (builtins.pathExists ./private.nix) ./private.nix);

  config = lib.mkDefault {
    nixpkgs.config.allowUnfree = true;

    userSettings = {
      defaultPkgs = pkgs-stable;

      stylix = {
        enable = true;
        theme = "gruvbox-dark-medium";
      };

      vim = {
        enable = true;
      };

      git = {
        enable = true;
        userName = "nathan.champagne";
        userEmail = "nathan.champagne@epita.fr";
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
        fish = {
          enable = true;
        };
        bash = {
          enable = true;
        };
        default = "fish";
      };


      terminal = {
        kitty = {
          enable = true;
        };
        foot = {
          enable = true;
        };
        alacritty = {
          enable = true;
        };
        default = "kitty";
      };
    };
  };
}