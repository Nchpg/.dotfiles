{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  postgresql = config.services.postgresql.enable;
  redis = config.systemSettings.authelia.enable;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana)
    mkTs
    byName
    thresholdLine
    ;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      # `runAsLocalSuperUser` : socket local sans mot de passe, lecture de toutes les vues d'administration.
      (lib.mkIf postgresql {
        services.prometheus.exporters.postgres = helpers.mkLocalExporter ports.postgres // {
          runAsLocalSuperUser = true;
        };

        systemSettings.monitoring.internal.scrapeJobs.postgres = helpers.localJob "postgres" ports.postgres;
      })

      {
        # `pg_up` et `redis_up` valent 0 quand l'exporteur joint son port mais pas sa base.
        systemSettings.monitoring.internal.alertRules.BaseDeDonneesInjoignable = {
          alert = "BaseDeDonneesInjoignable";
          expr = "pg_up == 0 or redis_up == 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Un exporteur de base de données n'atteint plus sa source ({{ $labels.job }}) : les courbes se vident sans que le service tombe.";
        };
      }

      (lib.mkIf (postgresql || redis) {
        systemSettings.monitoring.internal.panels.basesDeDonnees = mkTs {
          id = 38;
          title = "Bases de données : connexions";
          unit = "short";
          description = "Les deux bases dans le même panneau parce que l'alerte `BaseDeDonneesInjoignable` les couvre ensemble. Postgres plafonne à 100 connexions : c'est la saturation, et non la panne franche, qui se voit ici.";
          decimals = 0;
          targets = [
            {
              expr = "sum(pg_stat_database_numbackends)";
              legend = "postgres";
            }
            {
              expr = "pg_settings_max_connections";
              legend = "plafond postgres";
            }
            {
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
