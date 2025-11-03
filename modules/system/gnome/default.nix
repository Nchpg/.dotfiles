{ config, lib, pkgs-stable, ... }:

let
  cfg = config.systemSettings.window-manager.gnome;
in {
  options = {
    systemSettings.window-manager.gnome = {
      enable = lib.mkEnableOption "Enable gnome window manager";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.desktopManager.gnome.enable = true;
  };
}