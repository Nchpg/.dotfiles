{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  nextcloud = config.systemSettings.nextcloud;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;
in
{
  config =
    lib.mkIf (cfg.enable && cfg.apps.enable && nextcloud.enable && cfg.apps.nextcloudTokenKey != null)
      {
        services.prometheus.exporters.nextcloud = helpers.mkLocalExporter ports.nextcloudExporter // {
          # Jamais `hostName` : le nom public passe par le portail et l'exporteur y récolte du HTML.
          url = "https://${lib.head nextcloud.extraHostNames}";
          tokenFile = config.sops.secrets.${cfg.apps.nextcloudTokenKey}.path;
        };

        # `restartUnits` : l'exporteur lit le fichier au démarrage seulement.
        sops.secrets.${cfg.apps.nextcloudTokenKey} = {
          mode = "0400";
          owner = "nextcloud-exporter";
          restartUnits = [ "prometheus-nextcloud-exporter.service" ];
        };

        systemSettings.monitoring.internal = {
          # `serverinfo` recompte les fichiers : opération lourde.
          scrapeJobs.nextcloud = helpers.localJob "nextcloud" ports.nextcloudExporter // {
            scrape_interval = "5m";
            scrape_timeout = "1m";
          };

          # `nextcloud_up` tombe à 0 si l'API refuse l'exporteur (jeton faux, contournement Authelia cassé).
          alertRules.MetriquesNextcloudAveugles = {
            alert = "MetriquesNextcloudAveugles";
            expr = "nextcloud_up == 0";
            for = "30m";
            labels.severity = "warning";
            annotations.summary = "L'exporteur Nextcloud n'obtient plus rien de l'API serverinfo : jeton invalide, ou chemin non contourné dans Authelia.";
          };

          # Pas de panneau « mises à jour en attente » : ces métriques ne sortent pas ici (`updatenotification`).
          panels = {
            nextcloudComptes = mkTs {
              id = 28;
              title = "Nextcloud : comptes et partages";
              unit = "short";
              description = "Les partages sont ventilés par type plutôt que sommés : `link` est un partage PUBLIC, exposé à quiconque détient l'URL, là où `user` et `group` restent internes.";
              decimals = 0;
              targets = [
                {
                  expr = "nextcloud_users_total";
                  legend = "comptes";
                }
                {
                  expr = "nextcloud_active_users_daily_total";
                  legend = "actifs sur 24 h";
                }
                {
                  expr = "nextcloud_shares_total";
                  legend = "partages {{ type }}";
                }
              ];
            };

            nextcloudFichiers = mkTs {
              id = 33;
              title = "Nextcloud : fichiers";
              unit = "short";
              description = "Sa PENTE est ce qui compte : c'est le producteur d'inodes de la machine, à rapprocher du panneau « Inodes libres » de la section Stockage.";
              decimals = 0;
              targets = [
                {
                  expr = "nextcloud_files_total";
                  legend = "fichiers";
                }
              ];
            };

            nextcloudStockage = mkTs {
              id = 29;
              title = "Nextcloud : stockage";
              unit = "bytes";
              description = "Espace libre vu par l'instance elle-même, qui est celui de la racine : ce panneau et « Espace disque libre » décrivent le même disque par deux chemins différents.";
              targets = [
                {
                  expr = "nextcloud_free_space_bytes";
                  legend = "espace libre";
                }
              ];
            };

            nextcloudBase = mkTs {
              id = 34;
              title = "Nextcloud : base de données";
              unit = "bytes";
              description = "À part du panneau voisin bien qu'en octets comme lui : trois mille fois plus petit, il y serait une ligne collée à l'axe. C'est sa croissance qu'on vient voir.";
              targets = [
                {
                  expr = "nextcloud_database_size_bytes";
                  legend = "base de données";
                }
              ];
            };
          };
        };
      };
}
