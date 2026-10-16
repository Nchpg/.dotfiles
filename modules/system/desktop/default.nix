{ config, lib, ... }:

let
  cfg = config.systemSettings.desktop;
  wm = config.systemSettings.windowManager;
in
{
  options = {
    systemSettings.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = wm.sway.enable || wm.gnome.enable;
      description = ''
        Poste de travail : session graphique, son, Bluetooth, impression. Suit la présence d'un
        gestionnaire de fenêtres.
      '';

    };
  };

  config = {
    services.power-profiles-daemon.enable = cfg.enable;

    services.fwupd.enable = cfg.enable;
  };
}
