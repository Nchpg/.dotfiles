{ config, lib, pkgs-stable, pkgs-unstable, ... }:

{
  imports = (lib.optional (builtins.pathExists ./private.nix) ./private.nix);

  config = lib.mkDefault {
    nixpkgs.config.allowUnfree = true;

    userSettings = {
      defaultPkgs = pkgs-stable;
      
      stylix = {
        enable = true;
        theme = "custom";
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
      };
    };
  };
}