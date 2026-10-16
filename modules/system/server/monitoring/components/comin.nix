{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  comin = config.services.comin;
in
{
  config = lib.mkIf (cfg.enable && comin.enable) {
    systemSettings.monitoring.internal = {
      # Un comin arrêté est couvert par `CibleInjoignable`.
      scrapeJobs.comin = cfg.internal.helpers.localJob "comin" comin.exporter.port;

      alertRules = {
        # Seule alerte d'une évaluation cassée : comin ne lance `postBuildCommand` qu'après un build.
        DeploiementEnEchec = {
          alert = "DeploiementEnEchec";
          expr = "comin_last_eval_failed == 1 or comin_last_build_failed == 1 or comin_last_deployment_failed == 1";
          for = "2m";
          labels.severity = "critical";
          annotations.summary = "Le dernier commit de main n'a pas pu être déployé ({{ $labels.__name__ }}) : le serveur reste sur la version précédente. Détail : `comin status` et `journalctl -u comin`.";
        };

        DepotInjoignable = {
          alert = "DepotInjoignable";
          expr = "comin_last_fetch_failed == 1";
          for = "30m";
          labels.severity = "warning";
          annotations.summary = "comin n'arrive plus à lire le dépôt ({{ $labels.remote_name }}) depuis 30 minutes : plus aucun commit ne sera déployé.";
        };

        DeploiementSuspendu = {
          alert = "DeploiementSuspendu";
          expr = "comin_is_suspended == 1";
          for = "24h";
          labels.severity = "warning";
          annotations.summary = "comin est suspendu depuis plus d'un jour : `comin resume` pour reprendre les déploiements.";
        };

        # Le timer `gitops-reboot` aurait dû redémarrer dans la nuit.
        RedemarrageEnAttente = {
          alert = "RedemarrageEnAttente";
          expr = "comin_need_to_reboot == 1";
          for = "30h";
          labels.severity = "warning";
          annotations.summary = "Un déploiement a changé le noyau il y a plus de 30 h et le serveur n'a pas redémarré : vérifier `systemctl status gitops-reboot`.";
        };
      };
    };
  };
}
