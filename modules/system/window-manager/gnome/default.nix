{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.windowManager.gnome;
in
{
  options = {
    systemSettings.windowManager.gnome = {
      enable = lib.mkEnableOption "Enable gnome window manager";
      pkgs = myLib.mkPkgsOption {
        inherit lib config;
        default = pkgs-stable;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.desktopManager.gnome.enable = true;

    environment.gnome.excludePackages = with cfg.pkgs; [
      epiphany
      geary
      gnome-tour
      gnome-music
      gnome-maps
      gnome-weather
      gnome-contacts
      gnome-characters
      gnome-connections
      totem
      yelp
      simple-scan
    ];
  };
}
