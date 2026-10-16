{
  config,
  lib,
  pkgs-stable,
  target,
  ...
}:

# Déploiement en mode pull : comin suit la branche du dépôt et active chaque nouveau commit.
let
  cfg = config.systemSettings.gitops;

  # Même comparaison que `system.autoUpgrade.allowReboot` en amont.
  rebootIfNeeded = pkgs-stable.writeShellApplication {
    name = "gitops-reboot";
    runtimeInputs = with pkgs-stable; [
      coreutils
      procps
      systemd
    ];
    text = ''
      booted=$(readlink /run/booted-system/{initrd,kernel,kernel-modules})
      built=$(readlink /run/current-system/{initrd,kernel,kernel-modules})

      if [ "$booted" = "$built" ]; then
        echo "noyau et initrd inchangés depuis le démarrage : pas de redémarrage"
        exit 0
      fi

      # Un switch interrompu laisserait l'activation à moitié faite : on retente la nuit suivante.
      if pgrep -f switch-to-configuration > /dev/null; then
        echo "déploiement en cours : redémarrage reporté à la prochaine fenêtre"
        exit 0
      fi

      echo "noyau ou initrd changé depuis le démarrage : redémarrage"
      systemctl reboot
    '';
  };
in
{
  options.systemSettings.gitops = {
    enable = lib.mkEnableOption "déploiement continu du système depuis une branche git (comin)";

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://github.com/Nchpg/.dotfiles.git";
      description = "Dépôt suivi. Distant à dessein : la copie locale peut être en retard ou sale.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = ''
        Branche déployée en `switch`. `testing-<cible>` est appliquée en `test`
        (rien dans le chargeur de démarrage) tant qu'elle part de celle-ci.
      '';
    };

    reboot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Redémarre dans la fenêtre quand un déploiement a changé le noyau ou l'initrd.";
      };

      at = lib.mkOption {
        type = lib.types.str;
        default = "04:40";
        description = "Heure de la vérification, au format `OnCalendar` de systemd.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.url != null;
        message = "systemSettings.gitops.url est requis : c'est le dépôt que comin suit.";
      }
    ];

    services.comin = {
      enable = true;

      # Le nom de cible et non le hostname : `server-think-light` partage le hostname de `server-think`.
      hostname = target.name;

      remotes = lib.optional (cfg.url != null) {
        name = "origin";
        inherit (cfg) url;
        branches.main.name = cfg.branch;
      };

      # 0 (défaut) relance un build cassé toutes les 30 s sans fin.
      buildAttemptsLimit = 3;

      # Le défaut écoute sur toutes les interfaces.
      exporter.listen_address = "127.0.0.1";
    };

    systemSettings.notify.discord.units = [ "comin" ] ++ lib.optional cfg.reboot.enable "gitops-reboot";

    systemd.services.gitops-reboot = lib.mkIf cfg.reboot.enable {
      description = "Redémarre si le dernier déploiement a changé le noyau";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe rebootIfNeeded;
      };
    };

    systemd.timers.gitops-reboot = lib.mkIf cfg.reboot.enable {
      description = "Fenêtre de redémarrage après déploiement";
      wantedBy = [ "timers.target" ];
      # Pas de rattrapage : au démarrage, il n'y a justement rien à redémarrer.
      timerConfig.OnCalendar = cfg.reboot.at;
    };

    # Sans --delete-older-than, les anciennes générations restent des racines du GC.
    nix.gc = {
      automatic = lib.mkDefault true;
      options = lib.mkDefault "--delete-older-than 30d";
    };
  };
}
