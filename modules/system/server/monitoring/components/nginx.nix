{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  proxy = config.systemSettings.proxy;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      (lib.mkIf proxy.enable {
        services.nginx.virtualHosts."nginx-status" = {
          listen = [
            {
              addr = "127.0.0.1";
              port = ports.nginxStatus;
            }
          ];
          locations."/nginx_status".extraConfig = ''
            stub_status on;
            access_log off;
          '';
        };

        services.prometheus.exporters.nginx = helpers.mkLocalExporter ports.nginx // {
          scrapeUri = "http://127.0.0.1:${toString ports.nginxStatus}/nginx_status";
        };

        systemSettings.monitoring.internal.scrapeJobs.nginx = helpers.localJob "nginx" ports.nginx;
      })

      {
        systemSettings.monitoring.internal = {
          # L'exporteur répond mais à vide : `CibleInjoignable` ne l'attrape pas.
          alertRules.SondeApplicativeAveugle = {
            alert = "SondeApplicativeAveugle";
            expr = "nginx_up == 0 or increase(phpfpm_scrape_failures[15m]) > 0";
            for = "15m";
            labels.severity = "warning";
            annotations.summary = "Un exporteur applicatif ne parvient plus à lire sa source : la courbe est plate, pas calme.";
          };

          panels.nginx = mkTs {
            id = 24;
            title = "nginx : requêtes et connexions";
            unit = "short";
            description = "Les connexions « en attente » sont des connexions gardées ouvertes entre deux requêtes, pas des requêtes en souffrance : leur nombre est normal et suit le trafic.";
            decimals = 0;
            targets = [
              {
                expr = "rate(nginx_http_requests_total[5m]) * 60";
                legend = "requêtes/min";
              }
              {
                expr = "nginx_connections_active";
                legend = "connexions actives";
              }
              {
                expr = "nginx_connections_waiting";
                legend = "connexions en attente";
              }
            ];
          };
        };
      }
    ]
  );
}
