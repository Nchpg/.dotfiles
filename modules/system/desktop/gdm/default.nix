{ config, lib, ... }:

let
  cfg = config.systemSettings.desktop.gdm;
in
{
  options = {
    systemSettings.desktop.gdm.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.systemSettings.desktop.enable;
      description = "Écran de login GDM (et serveur X). Suit `systemSettings.desktop.enable`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.displayManager.gdm.enable = true;
    services.xserver.enable = true;

    # Déverrouille le trousseau "login" à la connexion (sinon Chrome réclame "Authentication required").
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.gdm-password.enableGnomeKeyring = true;
  };
}
