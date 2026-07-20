{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.window-manager.gnome;
in
{
  options = {
    systemSettings.window-manager.gnome = {
      enable = lib.mkEnableOption "Enable gnome window manager";
    };
  };

  config = lib.mkIf cfg.enable {
    services.desktopManager.gnome.enable = true;

    # Session de secours (la principale est sway) : suite d'apps retirée,
    # remplacée par équivalent home-manager. Garde nautilus/console/settings.
    environment.gnome.excludePackages = with pkgs-stable; [
      epiphany # navigateur (firefox/chrome via home-manager)
      geary # client mail
      gnome-tour
      gnome-music # spotify via home-manager
      gnome-maps
      gnome-weather
      gnome-contacts
      gnome-characters
      gnome-connections # client bureau à distance
      totem # lecteur vidéo (mpv via desktop-apps)
      yelp # visionneuse d'aide GNOME
      simple-scan
    ];
  };
}
