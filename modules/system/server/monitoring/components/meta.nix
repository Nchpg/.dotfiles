{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) q;
  inherit (myLib.server.grafana)
    mkStat
    mkStates
    mkAlertes
    steps
    ;
in
{
  config = lib.mkIf cfg.enable {
    systemSettings.monitoring.internal = {
      alertRules = {
        CibleInjoignable = {
          alert = "CibleInjoignable";
          expr = "up == 0";
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "La cible {{ $labels.instance }} (tâche {{ $labels.job }}) ne répond plus depuis 5 minutes.";
        };

        # Toujours en échec par construction ; sans dead man's switch ce serait une alerte de fond permanente.
        Watchdog = lib.mkIf cfg.deadManSwitch.enable {
          alert = "Watchdog";
          expr = "vector(1)";
          labels.severity = "none";
          annotations.summary = "Battement de cœur : cette alerte doit être en échec en permanence.";
        };

        # Part vers Discord : ne couvre que les pannes partielles, la totale est couverte par le watchdog.
        AlertmanagerNEnvoiePlus = {
          alert = "AlertmanagerNEnvoiePlus";
          expr = "rate(alertmanager_notifications_failed_total[15m]) > 0";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "Alertmanager échoue à notifier ({{ $labels.integration }}) : des alertes sont peut-être perdues.";
        };

        EvaluationDeReglesEnEchec = {
          alert = "EvaluationDeReglesEnEchec";
          expr = "increase(prometheus_rule_evaluation_failures_total[1h]) > 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Prometheus n'arrive plus à évaluer certaines règles : elles ne protègent plus de rien.";
        };
      };

      panels = {
        alertesEnCours = mkStat {
          id = 6;
          title = "Alertes en cours";
          unit = "short";
          description = "Nombre d'alertes actives en ce moment, watchdog exclu. Le détail est dans la section Surveillance, tout en bas.";
          # `or vector(0)` : sinon aucune alerte = « No Data ».
          expr = "count(${q.alertesActives}) or vector(0)";
          steps = steps "green" [
            1
            "red"
          ];
        };

        alertes = mkAlertes {
          id = 36;
          expr = q.alertesActives;
        };

        # Les sondes blackbox partagent une tâche par module : nommées par l'hôte de leur URL.
        ciblesDeCollecte = mkStates {
          h = 12;
          id = 20;
          title = "Cibles de collecte";
          description = "Une bande par cible de collecte. Rouge veut dire que Prometheus ne récupère plus ses métriques : les courbes qui en dépendent ne sont pas calmes, elles sont vides.";
          labels = {
            "0" = "ne répond plus";
            "1" = "collectée";
          };
          targets = [
            {
              expr = ''up{job!~"blackbox.*"}'';
              legend = "{{ job }}";
            }
            {
              expr = q.parCible ''up{job=~"blackbox.*"}'';
              legend = "sonde {{ cible }}";
            }
          ];
        };
      };
    };
  };
}
