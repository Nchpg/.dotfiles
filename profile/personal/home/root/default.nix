{ config, lib, pkgs-stable, pkgs-unstable, ... }:

{
  imports = (lib.optional (builtins.pathExists ./private.nix) ./private.nix);

  config = lib.mkDefault {
    nixpkgs.config.allowUnfree = true;

    userSettings = {
      defaultPkgs = pkgs-stable;

      vim.enable = true;

      git.enable = true;

      shell = {
        zsh.enable = true;
        bash.enable = true;
      };
    };
  };
}