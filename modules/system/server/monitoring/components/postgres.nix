{
  config,
  lib,
  myLib,
  ...
}:

# Les bases de données : PostgreSQL (celle de Nextcloud) et le Redis d'Authelia
# (dont l'exporteur est dans components/authelia.nix). Ici ce qu'elles ont en
# commun : la règle et le panneau qui les couvrent ensemble.
let
  cfg = config.systemSettings.monitoring;
  postgresql = config.services.postgresql.enable;
  redis = config.systemSettings.authelia.enable;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.grafana)
    mkTs
    byName
    thresholdLine
    ;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      # Une panne franche se voit déjà par la sonde `status.php`, qui interroge
      # PHP ET la base ; ce que celui-ci ajoute est ce qui PRÉCÈDE la panne —
      # connexions qui saturent, transactions qui traînent, cache qui ne tient
      # plus.
      #
      # `runAsLocalSuperUser` : l'exporteur se connecte par le socket local en
      # `postgres`, donc sans mot de passe à ranger nulle part. C'est un
      # privilège réel — lecture de toutes les vues d'administration — à mettre
      # en regard du fait qu'il ne sort rien de la machine.
      (lib.mkIf postgresql {
        services.prometheus.exporters.postgres = helpers.mkLocalExporter ports.postgres // {
          runAsLocalSuperUser = true;
        };

        systemSettings.monitoring.internal.scrapeJobs.postgres = helpers.localJob "postgres" ports.postgres;
      })

      {
        # MÊME NATURE que `SondeApplicativeAveugle`, pour les deux bases. `pg_up`
        # et `redis_up` sont publiés par les exporteurs eux-mêmes et valent 0
        # quand ils joignent leur port mais pas leur base — mot de passe, socket
        # disparu, ou droits perdus sur le socket.
        #
        # Noms RELEVÉS sur les `/metrics` en fonctionnement, pas supposés : les
        # binaires de ces deux exporteurs assemblent leurs noms à l'exécution.
        systemSettings.monitoring.internal.alertRules.BaseDeDonneesInjoignable = {
          alert = "BaseDeDonneesInjoignable";
          expr = "pg_up == 0 or redis_up == 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Un exporteur de base de données n'atteint plus sa source ({{ $labels.job }}) : les courbes se vident sans que le service tombe.";
        };
      }

      # Une alerte dit qu'un seuil est franchi, elle ne dit pas à quoi
      # ressemblait l'avant : sans ce panneau, les séries de ces exporteurs
      # seraient collectées sans jamais être lues.
      #
      # Dès que L'UNE des deux bases est exportée : le panneau trace les deux.
      (lib.mkIf (postgresql || redis) {
        systemSettings.monitoring.internal.panels.basesDeDonnees = mkTs {
          id = 38;
          title = "Bases de données : connexions";
          unit = "short";
          description = "Les deux bases dans le même panneau parce que l'alerte `BaseDeDonneesInjoignable` les couvre ensemble. Postgres plafonne à 100 connexions : c'est la saturation, et non la panne franche, qui se voit ici.";
          decimals = 0;
          targets = [
            {
              # Sommé plutôt que ventilé par base : le plafond de Postgres est
              # global, donc c'est le total qui s'en approche.
              expr = "sum(pg_stat_database_numbackends)";
              legend = "postgres";
            }
            {
              # Le plafond tracé avec la mesure, en référence.
              expr = "pg_settings_max_connections";
              legend = "plafond postgres";
            }
            {
              # L'instance d'Authelia, la seule des deux qui soit exportée (cf.
              # components/authelia.nix).
              expr = "redis_connected_clients";
              legend = "redis (authelia)";
            }
          ];
          overrides = [ (thresholdLine (byName "plafond postgres")) ];
        };
      })
    ]
  );
}
