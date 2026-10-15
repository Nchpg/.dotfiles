{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# PHP-FPM, le pool de Nextcloud : ce qui sature quand « Nextcloud rame »
# pendant que la machine, elle, a l'air au repos.
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
        # PHP-FPM ne publie son état que si on lui désigne un chemin pour ça ;
        # sans cette ligne l'exporteur démarre et ne trouve rien.
        services.phpfpm.pools.nextcloud.settings."pm.status_path" = "/status";

        services.prometheus.exporters.php-fpm = helpers.mkLocalExporter ports.phpfpm // {
          # L'adresse de collecte ne passe que par l'environnement, le module
          # amont n'exposant pas d'option dédiée. Le fichier va dans le store
          # SANS réserve : il ne contient qu'un chemin de socket, aucun secret.
          environmentFile = pkgs-stable.writeText "php-fpm-exporter.env" ''
            PHP_FPM_SCRAPE_URI="unix:///run/phpfpm/nextcloud.sock;/status"
          '';
        };

        # Le socket du pool est en 0660 nginx:nginx, et l'exporteur tourne sous
        # un utilisateur dynamique : sans appartenance au groupe, il démarre et
        # se voit refuser la connexion. Lecture d'un état, aucun droit sur les
        # fichiers de Nextcloud, qui appartiennent à un autre utilisateur.
        systemd.services.prometheus-php-fpm-exporter.serviceConfig = {
          SupplementaryGroups = [ "nginx" ];

          # Le durcissement amont n'autorise que AF_INET et AF_INET6, si bien que
          # l'exporteur ne peut pas OUVRIR le socket du pool : il sort en « exit
          # status 2 » sans un mot de plus, et le journal ne nomme jamais l'appel
          # refusé — c'est le mode d'échec normal d'un filtre systemd.
          #
          # La liste est concaténée, pas remplacée : AF_INET et AF_INET6 restent
          # en place pour l'écoute HTTP des métriques.
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };

        systemSettings.monitoring.internal.scrapeJobs.php-fpm = helpers.localJob "php-fpm" ports.phpfpm;
      })

      {
        systemSettings.monitoring.internal = {
          # `max_children_reached` est un compteur : PHP-FPM l'incrémente chaque
          # fois qu'il aurait voulu démarrer un processus de plus et n'a pas pu.
          # Sa valeur absolue ne dit rien — elle date peut-être du mois dernier —
          # donc la règle porte sur la PROGRESSION.
          #
          # C'est la traduction mesurable de « Nextcloud rame » : le pool est au
          # plafond, les requêtes attendent, et rien côté machine ne le montre
          # puisqu'un processus en attente ne consomme rien.
          alertRules.PoolPhpSature = {
            alert = "PoolPhpSature";
            expr = "increase(phpfpm_max_children_reached[15m]) > 0";
            for = "5m";
            labels.severity = "warning";
            annotations.summary = "Le pool PHP-FPM de Nextcloud a atteint son plafond de processus : les requêtes attendent.";
          };

          # `listen_queue` EST LE SIGNAL, les deux autres ne sont là que pour le
          # lire : une file qui monte alors que les processus actifs plafonnent
          # veut dire que le pool est au maximum et que les requêtes patientent.
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
