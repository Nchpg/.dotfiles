{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.firefox;
in {
  options = {
    userSettings.firefox = {
      enable = lib.mkEnableOption "Enable firefox browser";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.firefox = {
        enable = true;
        package = cfg.pkgs.firefox;
    };
  };
}