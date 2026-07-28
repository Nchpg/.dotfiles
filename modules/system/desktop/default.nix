{ config, lib, ... }:

let
  wm = config.systemSettings.windowManager;
in
{
  # Drapeau de POLITIQUE, pas un module de service : il ne configure rien
  # lui-même, il dit ce qu'est la machine. Les modules concernés le lisent
  # (gdm, hardware/audio, hardware/bluetooth, configuration.nix).
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
}
