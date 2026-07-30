{
  config,
  lib,
  ...
}:

# Mises à jour automatiques du système. Pertinent sur un host qui expose des
# services : la quasi-totalité des compromissions à distance réelles exploitent
# une faille DÉJÀ corrigée, donc appliquer les correctifs sans dépendre de la
# mémoire de quelqu'un vaut plus que n'importe quelle couche supplémentaire.
let
  cfg = config.systemSettings.autoUpgrade;
in
{
  options.systemSettings.autoUpgrade = {
    enable = lib.mkEnableOption "mises à jour automatiques du système";

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "github:Nchpg/.dotfiles#server-think";
      description = ''
        Flake à construire, cible comprise. Doit être une URL DISTANTE : l'unité
        tourne sans que personne n'ait fait de `git pull`, et la copie locale du
        dépôt n'est pas forcément à jour.
      '';
    };

    reboot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Redémarre quand la mise à jour touche le noyau ou l'initrd. Sans lui, un
        correctif noyau reste inactif jusqu'au prochain redémarrage manuel,
        c'est-à-dire potentiellement des mois — soit exactement le trou qu'on
        cherche à fermer.
      '';
    };

    window = lib.mkOption {
      type = lib.types.str;
      default = "04:40";
      description = ''
        Heure de passage, au format systemd (`OnCalendar`). Creuse de nuit pour
        qu'un redémarrage ne coupe personne en pleine synchronisation.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "systemSettings.autoUpgrade.flake est requis : sans URL distante, l'unité reconstruirait la copie locale du dépôt, qui n'est pas forcément à jour.";
      }
    ];

    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake;
      # Le décalage évite qu'un rebuild démarre pile à l'heure ronde où tournent
      # déjà les autres timers du système.
      dates = cfg.window;
      randomizedDelaySec = "30min";

      # Redémarrage seulement si le noyau ou l'initrd ont changé : le reste
      # s'applique à chaud par un switch, sans couper les services.
      allowReboot = cfg.reboot;
      rebootWindow = {
        lower = "04:00";
        upper = "06:00";
      };

      # `switch` et pas `boot` : les correctifs des services (nginx, PHP,
      # Authelia) prennent effet tout de suite plutôt que d'attendre un
      # redémarrage dont ils n'ont pas besoin.
      operation = "switch";
    };

    # Une montée par nuit, donc une génération par nuit. L'ESP est déjà borné
    # par `configurationLimit` (cf. modules/system/boot) ; c'est la racine qui
    # se remplit, et `nix.gc.automatic` seul n'y change rien : sans
    # `--delete-older-than`, les anciennes générations restent des racines du
    # ramasse-miettes et rien n'est libéré.
    nix.gc = {
      automatic = lib.mkDefault true;
      options = lib.mkDefault "--delete-older-than 30d";
    };
  };
}
