{ config, lib, ... }:

# Gestion du swap, en trois briques indépendantes (chacune opt-in) :
#   - zram     : swap compressé EN RAM (zstd ~3:1). Aucune usure SSD, ordres de
#                grandeur plus rapide qu'un swap disque. Utilisé en premier
#                (priorité haute).
#   - file /   : swap disque classique (filet supplémentaire, hibernation...).
#     partition  Non utilisés sur gram, gardés pour la flexibilité multi-host.
#   - earlyoom : tue le plus gros process AVANT l'épuisement total de la
#                mémoire → un hoquet court au lieu d'un freeze de plusieurs
#                minutes (thrashing) suivi d'un OOM-kill noyau aveugle.
let
  cfg = config.systemSettings.swap;
in
{
  options = {
    systemSettings.swap = {
      zram = {
        enable = lib.mkEnableOption "swap compressé en RAM (zram)";
        memoryPercent = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = ''
            Taille NON compressée du périphérique zram, en % de la RAM.
            Avec zstd (~3:1), 100 % ne coûte réellement qu'environ un tiers
            de la RAM une fois plein.
          '';
        };
      };

      file = {
        enable = lib.mkEnableOption "fichier de swap sur disque";
        path = lib.mkOption {
          type = lib.types.str;
          default = "/swapfile";
          description = "Chemin du fichier de swap (créé automatiquement).";
        };
        size = lib.mkOption {
          type = lib.types.int;
          default = 4 * 1024;
          description = "Taille du fichier de swap en Mo.";
        };
      };

      partition = {
        enable = lib.mkEnableOption "partition de swap";
        device = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Chemin du périphérique de la partition de swap.";
        };
      };

      earlyoom = {
        enable = lib.mkEnableOption "earlyoom (OOM-killer anticipé)";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.zram.enable {
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = cfg.zram.memoryPercent;
        # Plus haut que le swap disque (-2 par défaut) : zram se remplit d'abord.
        priority = 100;
      };

      boot.kernel.sysctl = {
        # zram n'a pas de coût de seek : on swappe agressivement (150 > 100,
        # le noyau préfère swapper plutôt qu'évincer le cache disque) et on
        # coupe le readahead (inutile en RAM).
        "vm.swappiness" = 150;
        "vm.page-cluster" = 0;
      };
    })

    {
      swapDevices =
        lib.optional cfg.file.enable {
          device = cfg.file.path;
          size = cfg.file.size;
        }
        ++ lib.optional (cfg.partition.enable && cfg.partition.device != null) {
          device = cfg.partition.device;
        };
    }

    (lib.mkIf cfg.earlyoom.enable {
      services.earlyoom = {
        enable = true;
        # Agit quand RAM ET swap passent sous 5 % libres (SIGTERM), SIGKILL à 2,5 %.
        freeMemThreshold = 5;
        freeSwapThreshold = 5;
        # Notification desktop au kill (via le daemon de notifs de la session).
        # Le module upstream avertit que n'importe quel utilisateur LOCAL peut
        # alors spammer des notifications (DoS) — sans risque en mono-user
        # (systemSettings.users n'a que nchpg/guest de confiance), à
        # réévaluer si un compte non-fiable est ajouté un jour.
        enableNotifications = true;
        extraArgs = [
          # Sacrifier un navigateur en priorité, jamais la session elle-même
          # (sway/waybar/gdm). Pas de `node` ici : Claude Code et les serveurs
          # de dev sont des process node — on les laisse en cibles ordinaires
          # (earlyoom prend alors le plus gros consommateur).
          "--prefer"
          "^(chrome|chromium|firefox)$"
          "--avoid"
          "^(sway|waybar|gdm|gnome-shell|Xwayland|systemd|dbus-daemon)$"
        ];
      };
    })
  ];
}
