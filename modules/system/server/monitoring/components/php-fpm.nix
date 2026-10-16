{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  nextcloud = config.systemSettings.nextcloud;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      (lib.mkIf nextcloud.enable {
        services.phpfpm.pools.nextcloud.settings."pm.status_path" = "/status";

        services.prometheus.exporters.php-fpm = helpers.mkLocalExporter ports.phpfpm // {
          # Le module amont n'expose l'adresse de collecte que par l'environnement.
          environmentFile = pkgs-stable.writeText "php-fpm-exporter.env" ''
            PHP_FPM_SCRAPE_URI="unix:///run/phpfpm/nextcloud.sock;/status"
          '';
        };

        # Le socket du pool est en 0660 nginx:nginx.
        systemd.services.prometheus-php-fpm-exporter.serviceConfig = {
          SupplementaryGroups = [ "nginx" ];

          # Sans AF_UNIX l'exporteur sort en « exit status 2 » sans nommer l'appel refusé.
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };

        systemSettings.monitoring.internal.scrapeJobs.php-fpm = helpers.localJob "php-fpm" ports.phpfpm;
      })

      {
        systemSettings.monitoring.internal = {
          # `max_children_reached` est un compteur : seule sa progression compte.
          alertRules.PoolPhpSature = {
            alert = "PoolPhpSature";
            expr = "increase(phpfpm_max_children_reached[15m]) > 0";
            for = "5m";
            labels.severity = "warning";
            annotations.summary = "Le pool PHP-FPM de Nextcloud a atteint son plafond de processus : les requêtes attendent.";
          };

          panels.phpFpm = mkTs {
            id = 25;
            title = "PHP-FPM : pool Nextcloud";
            unit = "short";
            description = "La file d'attente est le signal, les deux autres servent à la lire : une file qui monte pendant que les processus actifs plafonnent, c'est la forme exacte que prend « Nextcloud est lent ».";
            decimals = 0;
            targets = [
              {
                expr = "phpfpm_active_processes";
                legend = "actifs";
              }
              {
                expr = "phpfpm_idle_processes";
                legend = "au repos";
              }
              {
                expr = "phpfpm_listen_queue";
                legend = "en file d'attente";
              }
            ];
          };
        };
      }
    ]
  );
}
