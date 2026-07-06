{ config, lib, pkgs-stable, ... }:

let
  cfg = config.systemSettings.window-manager.sway;
in {
  options = {
    systemSettings.window-manager.sway = {
      enable = lib.mkEnableOption "Enable sway window manager";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
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

    # Partage d'écran (Discord/Chrome) sur Wayland : active xdg-desktop-portal
    # avec le backend wlroots + PipeWire. programs.sway route déjà ScreenCast/
    # Screenshot vers wlr ; ici on active le portail et on s'assure que gtk est
    # présent pour le reste (FileChooser, etc.).
    xdg.portal = {
      enable = true;
      wlr.enable = true; # backend Screencast/Screenshot pour wlroots
      extraPortals = [ pkgs-stable.xdg-desktop-portal-gtk ];

      # Routage des interfaces de portail. Sans ça, avec XDG_CURRENT_DESKTOP=sway
      # et plusieurs backends, FileChooser n'est servi par personne (dialogue Qt
      # moche dans flameshot). On met gtk par défaut (joli sélecteur de fichiers)
      # tout en gardant wlr pour la capture/partage d'écran.
      config.common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
      };
    };
  };
}
