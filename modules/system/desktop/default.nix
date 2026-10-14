{ config, lib, ... }:

let
  cfg = config.systemSettings.desktop;
  wm = config.systemSettings.windowManager;
in
{
  # Drapeau de POLITIQUE : il dit ce qu'est la machine. Les services qui n'ont
  # de sens que sur un poste vivent sous ce dossier (audio, bluetooth, gdm,
  # printing), ceux trop petits pour un dossier juste en dessous. D'autres
  # modules le lisent pour leur part de bureau (storage/disks, stylix).
  options = {
    systemSettings.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = wm.sway.enable || wm.gnome.enable;
      description = ''
        Ce host est un poste de travail : session graphique, son, Bluetooth,
        impression et découverte réseau. Suit par défaut la présence d'un
        gestionnaire de fenêtres — un profil headless le met à `false` et
        tout tombe d'un coup.

        Un seul drapeau plutôt qu'un `enable` par service : ces briques n'ont
        aucune raison d'être décidées séparément, et un profil serveur qui
        devrait les couper une à une en oublierait fatalement une. Le jour où
        l'une d'elles doit vraiment diverger, elle prendra son option propre.
      '';
    };
  };

  config = {
    # Utilisé par lg-control et le module batterie de waybar. Explicite : sinon
    # fourni seulement en dépendance cachée du module GNOME.
    services.power-profiles-daemon.enable = cfg.enable;

    # LVFS, passif (rien ne se flashe sans fwupdmgr update manuel).
    services.fwupd.enable = cfg.enable;
  };
}
