{ config, lib, pkgs-stable, ... }:

let
  cfg = config.systemSettings.window-manager.sway;
in {
  options = {
    systemSettings.window-manager.sway = {
      enable = lib.mkEnableOption "Enable sway window manager";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = pkgs-stable;
        description = "Pkgs to use";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };
  };
}