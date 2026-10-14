{ config, lib, ... }:

let
  cfg = config.systemSettings.desktop.gdm;
in
{
  options = {
    systemSettings.desktop.gdm.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.systemSettings.desktop.enable;
      description = ''
        Écran de login GDM (et serveur X). Suit par défaut
        `systemSettings.desktop.enable` : un profil headless n'a aucune
        session graphique à ouvrir, et tirer GDM + Xorg sur une machine sans
        écran n'ajoute qu'une surface d'attaque.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.displayManager.gdm.enable = true;
    services.xserver.enable = true;

    # Le hook PAM déverrouille le trousseau "login" avec le mot de passe de
    # session à la connexion, sinon Chrome réclame "Authentication required".
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.gdm-password.enableGnomeKeyring = true;
  };
}
