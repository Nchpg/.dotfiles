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

  # Fenêtre de redémarrage déduite de `window` quand celle-ci est une heure
  # simple (`HH:MM`) : de l'heure pleine qui la précède à deux heures plus
  # tard, ce qui couvre le délai aléatoire de trente minutes et la durée du
  # build. `null` pour toute autre forme d'`OnCalendar` (`Sun 04:40`,
  # `daily`…), qu'on ne sait pas convertir : l'assertion réclame alors
  # `rebootWindow` explicitement.
  derivedRebootWindow =
    let
      m = builtins.match "([0-9]{1,2}):[0-9]{2}" cfg.window;
      hour = lib.toIntBase10 (lib.head m);
      fmt = h: "${lib.fixedWidthString 2 "0" (toString (lib.mod h 24))}:00";
    in
    if m == null then
      null
    else
      {
        lower = fmt hour;
        upper = fmt (hour + 2);
      };
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

    rebootWindow = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            lower = lib.mkOption {
              type = lib.types.str;
              example = "04:00";
              description = "Début de la plage, `HH:MM`.";
            };
            upper = lib.mkOption {
              type = lib.types.str;
              example = "06:00";
              description = "Fin de la plage, `HH:MM`.";
            };
          };
        }
      );
      default = derivedRebootWindow;
      defaultText = lib.literalExpression "de l'heure pleine de `window` à deux heures plus tard, si `window` est de la forme HH:MM";
      description = ''
        Plage horaire hors de laquelle le redémarrage n'a PAS lieu, même si la
        mise à jour le demande. Suit `window` par défaut : une plage figée
        laisserait un `window` déplacé à 13:00 construire, puis ne jamais
        redémarrer — le correctif noyau resterait inactif sans un mot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "systemSettings.autoUpgrade.flake est requis : sans URL distante, l'unité reconstruirait la copie locale du dépôt, qui n'est pas forcément à jour.";
      }
      {
        assertion = !cfg.reboot || cfg.rebootWindow != null;
        message = "systemSettings.autoUpgrade : `window` (${cfg.window}) n'est pas de la forme HH:MM, la plage de redémarrage ne peut pas en être déduite. Renseigne rebootWindow.";
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
      inherit (cfg) rebootWindow;

      # `switch` et pas `boot` : les correctifs des services (nginx, PHP,
      # Authelia) prennent effet tout de suite plutôt que d'attendre un
      # redémarrage dont ils n'ont pas besoin.
      operation = "switch";
    };

    # SIGNALEMENT IMMÉDIAT DE L'ÉCHEC, comme nginx, Loki ou Vaultwarden.
    #
    # C'était la seule unité importante du host à ne pas l'avoir, et c'est
    # justement celle qui a le plus de raisons de l'avoir : elle est la SEULE à
    # modifier le système sans que personne ne regarde. Un flake qui ne construit
    # plus — une entrée amont cassée, un patch Nextcloud qui ne s'applique plus —
    # laisse la machine sur son ancienne génération, donc en état de marche,
    # donc parfaitement silencieuse. Les correctifs de sécurité cessent
    # simplement d'arriver, ce qui est exactement le trou que ce module existe
    # pour fermer.
    #
    # `UniteSystemdEnEchec` finit par le dire (cf. modules/system/server/monitoring),
    # mais après dix minutes d'état en échec et par le détour d'Alertmanager. Sur
    # une unité qui ne tourne qu'une fois par nuit, autant être prévenu tout de
    # suite.
    #
    # Le nom de l'unité est celui que pose le module amont pour `system.autoUpgrade`.
    systemSettings.notify.discord.units = [ "nixos-upgrade" ];

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
