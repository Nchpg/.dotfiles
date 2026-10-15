{
  config,
  lib,
  myLib,
  ...
}:

# nginx, par son `stub_status` : les requêtes et les connexions que la
# machine ne voit pas.
#
# Comme pour chaque exporteur applicatif, l'exporteur suit le service qu'il
# observe : allumer celui de nginx sur une machine sans proxy ne produirait pas
# une erreur, mais une tâche de collecte en échec permanent, donc une alerte
# `CibleInjoignable` qui hurle sans rien signaler.
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
        # `stub_status` sur un socket À PART, cf. le commentaire des ports
        # (internal.nix) : c'est le seul moyen d'obtenir les compteurs de nginx
        # sans toucher au port 80 ni à l'ordre des vhosts. Pas de `enableACME`
        # ni de TLS, l'écoute étant sur la boucle locale et le contenu étant sept
        # entiers sans intérêt pour personne.
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
          # L'exporteur joint sa cible mais s'en fait rejeter — socket absent,
          # `pm.status_path` disparu, `stub_status` retiré. `CibleInjoignable` ne
          # l'attrape PAS : de son point de vue l'exporteur répond très bien, il
          # répond juste du vide.
          #
          # DEUX FORMES, nginx et PHP-FPM, parce que les deux exporteurs ne
          # comptent pas pareil, et ça se vérifie dans les binaires plutôt que
          # par symétrie : nginx publie un `nginx_up`, php-fpm n'a AUCUN
          # `phpfpm_up` mais un compteur d'échecs cumulatif, donc une
          # progression.
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
                # PAR MINUTE : un taux par seconde sur cette machine s'affiche en
                # centièmes, qu'il faut convertir de tête.
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
