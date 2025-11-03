{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.shell.zsh;
in {
  options = {
    userSettings.shell.zsh = {
      enable = lib.mkEnableOption "Enable zsh";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      package = cfg.pkgs.zsh;
      enableCompletion = true;
      history = {
        ignoreDups = true;
        extended = true;
      };
      initContent = builtins.readFile ./.zshrc;
    };
  };
}