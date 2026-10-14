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

    # Session de secours (la principale est sway) : suite d'apps retirée,
    # remplacée par équivalent home-manager. Garde nautilus/console/settings.
    environment.gnome.excludePackages = with cfg.pkgs; [
      epiphany # navigateur (firefox/chrome via home-manager)
      geary # client mail
      gnome-tour
      gnome-music # spotify via home-manager
      gnome-maps
      gnome-weather
      gnome-contacts
      gnome-characters
      gnome-connections # client bureau à distance
      totem # lecteur vidéo (mpv via gui)
      yelp # visionneuse d'aide GNOME
      simple-scan
    ];
  };
}
