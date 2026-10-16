{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  cloudflared = config.systemSettings.cloudflared;
  nextcloud = config.systemSettings.nextcloud;
  proxy = config.systemSettings.proxy;
in
{
  options.systemSettings.monitoring = {
    enable = lib.mkEnableOption "surveillance du host (Prometheus, Alertmanager, Grafana)";

    retention = lib.mkOption {
      type = lib.types.str;
      default = "90d";
      description = "Durée de conservation des mesures par Prometheus.";
    };

    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = "Fréquence de collecte des métriques locales (les sondes blackbox ont la leur).";
    };

    blackbox.targets = lib.mkOption {
      default = { };
      description = ''
        Points sondés par une requête HTTP. Sans cible, l'exporteur blackbox ne tourne pas.
        dnsmasq réécrit les noms publics : la sonde ne traverse pas le tunnel Cloudflare.
      '';
      example = lib.literalExpression ''
        {
          nextcloud = {
            url = "https://cloud.exemple.fr/status.php";
            module = "http_2xx";
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "URL complète à sonder, schéma compris.";
            };

            module = lib.mkOption {
              type = lib.types.enum [
                "http_2xx"
                "http_authelia"
              ];
              default = "http_2xx";
              description = ''
                Réponse attendue : `http_2xx` (un 2xx) ou `http_authelia` (redirection vers le portail).
              '';
            };
          };
        }
      );
    };

    disks = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Relève l'état SMART des disques et alerte dessus.
        '';
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/dev/nvme0n1" ];
        description = "Disques à interroger. Vide : l'exporteur les découvre seul.";
      };
    };

    logs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Collecte le journal (journald et nginx) dans Loki, via Vector.
        '';
      };

      kernelAlerts = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Règle Loki sur les erreurs de disque du noyau (liaison SATA perdue, erreur d'E/S).
          '';
        };
      };

      retention = lib.mkOption {
        type = lib.types.str;
        default = "30d";
        description = ''
          Durée de conservation des journaux.
        '';
      };

      excludeUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "prometheus-blackbox-exporter.service" ];
        description = ''
          Unités dont le journal n'est pas envoyé (nom complet).
        '';
      };
    };

    apps = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Métriques applicatives : nginx, PHP-FPM, Authelia (et Redis), PostgreSQL,
          WireGuard, dnsmasq. Chaque exporteur n'est activé que si son service l'est.
        '';
      };

      nextcloudTokenKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "nextcloud/serverinfo_token";
        description = ''
          Clé sops du jeton `serverinfo` de Nextcloud. `null` : exporteur Nextcloud éteint.
          Génération : `nextcloud-occ config:app:set serverinfo token --value "$(openssl rand -hex 32)"`.
        '';
      };
    };

    grafana = {
      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "metrics.exemple.fr";
        description = ''
          Nom sous lequel Grafana est servi, couvert par le domaine de session d'Authelia.
        '';
      };

      public = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Publie Grafana par le tunnel, en plus du LAN et du VPN.
        '';
      };
    };

    deadManSwitch = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Battement de cœur périodique vers un service tiers, qui prévient quand il cesse
          d'arriver. Porte l'alerte `Watchdog`.
        '';
      };

      pingUrlKey = lib.mkOption {
        type = lib.types.str;
        default = "healthchecks/ping_url";
        description = "Clé sops de l'URL de ping (secrets système).";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Période entre deux battements.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.grafana.hostName != null;
        message = "systemSettings.monitoring : grafana.hostName est requis, c'est le nom du vhost qui sert l'interface.";
      }
      {
        assertion = authelia.enable;
        message = ''
          systemSettings.monitoring exige systemSettings.authelia.enable.
          Grafana montre la topologie de la machine, ses points de montage et l'état de ses
          services : il n'est servi derrière aucune authentification propre (le formulaire de
          connexion est coupé au profit du portail), donc sans Authelia il serait en accès libre.
        '';
      }
      {
        assertion = proxy.enable;
        message = "systemSettings.monitoring exige systemSettings.proxy.enable (nginx et le certificat du vhost Grafana).";
      }
      {
        assertion = !cfg.grafana.public || cloudflared.enable;
        message = "systemSettings.monitoring.grafana.public exige systemSettings.cloudflared.enable, aucun port n'étant ouvert sur la box.";
      }
      {
        assertion = cfg.apps.nextcloudTokenKey == null || nextcloud.extraHostNames != [ ];
        message = ''
          systemSettings.monitoring.apps.nextcloudTokenKey exige au moins un systemSettings.nextcloud.extraHostNames.
          L'exporteur interroge l'API serverinfo sous le nom INTERNE, celui que la règle de contournement
          d'Authelia laisse passer : sous le nom public il reçoit la page de connexion du portail et échoue
          sur « invalid character '<' », du HTML là où il attend du JSON.
        '';
      }
    ];

    warnings = lib.optional (!cfg.deadManSwitch.enable) ''
      systemSettings.monitoring : aucun dead man's switch sur ce host.
      Prometheus, Alertmanager et le notifieur Discord tournent tous SUR la machine surveillée :
      si elle s'arrête, plus rien n'est envoyé et le silence ressemble exactement à « tout va bien ».
      Active systemSettings.monitoring.deadManSwitch.
    '';
  };
}
