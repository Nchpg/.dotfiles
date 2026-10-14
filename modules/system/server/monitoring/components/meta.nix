{
  config,
  lib,
  myLib,
  ...
}:

# La surveillance de la surveillance : les cibles de collecte, la chaîne
# d'alerte elle-même, et les alertes en cours.
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) q;
  inherit (myLib.grafana)
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

        # CONDITIONNÉE AU DEAD MAN'S SWITCH, seul consommateur qu'elle ait.
        #
        # Elle est toujours en échec par construction, et c'est tout son
        # intérêt : elle ne prévient d'aucun problème, elle PROUVE QUE LA CHAÎNE
        # FONCTIONNE — Prometheus évalue, Alertmanager route, le réseau sort.
        # Alertmanager l'envoie en boucle au tiers ; c'est son ARRÊT qui alerte,
        # hors de cette machine.
        #
        # Sans destinataire, elle resterait affichée en permanence dans
        # Alertmanager et dans Grafana : une alerte de fond en face de laquelle
        # on apprend à ne plus regarder.
        Watchdog = lib.mkIf cfg.deadManSwitch.enable {
          alert = "Watchdog";
          expr = "vector(1)";
          labels.severity = "none";
          annotations.summary = "Battement de cœur : cette alerte doit être en échec en permanence.";
        };

        # IRONIE ASSUMÉE : si Discord est injoignable, cette alerte part vers
        # Discord. Elle n'a donc de valeur que pour les pannes PARTIELLES —
        # jeton révoqué, salon supprimé, limitation de débit — où le reste passe
        # encore. La panne totale est couverte par le watchdog, pas par elle.
        AlertmanagerNEnvoiePlus = {
          alert = "AlertmanagerNEnvoiePlus";
          expr = "rate(alertmanager_notifications_failed_total[15m]) > 0";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "Alertmanager échoue à notifier ({{ $labels.integration }}) : des alertes sont peut-être perdues.";
        };

        # Une règle qui n'arrive plus à s'évaluer ne dit rien, et son silence
        # ressemble à l'absence de problème.
        EvaluationDeReglesEnEchec = {
          alert = "EvaluationDeReglesEnEchec";
          expr = "increase(prometheus_rule_evaluation_failures_total[1h]) > 0";
          for = "10m";
          labels.severity = "warning";
          annotations.summary = "Prometheus n'arrive plus à évaluer certaines règles : elles ne protègent plus de rien.";
        };
      };

      panels = {
        # EN TÊTE DU TABLEAU, avant les mesures de la machine : c'est le seul
        # chiffre qui dise si quelque chose RÉCLAME une action. Il double la
        # table détaillée de la section Surveillance, et le doublon est le
        # sujet : personne ne fait défiler jusqu'en bas quand tout a l'air
        # normal.
        alertesEnCours = mkStat {
          id = 6;
          title = "Alertes en cours";
          unit = "short";
          description = "Nombre d'alertes actives en ce moment, watchdog exclu. Le détail est dans la section Surveillance, tout en bas.";
          # `or vector(0)` : sans lui, l'absence d'alerte n'est aucune série,
          # donc « No Data » — qui ne distingue pas « rien » de « je ne sais
          # pas ». Un zéro affiché dit que la mesure a eu lieu.
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

        # `up` par cible : c'est la santé de la COLLECTE elle-même. Une tâche
        # tombée ne rend pas ses métriques fausses, elle les fait disparaître —
        # et un graphe vide ressemble à un graphe calme.
        #
        # DEUX CIBLES SÉPARÉES, parce que `job` ne suffit pas à nommer une sonde :
        # les sondes blackbox partagent une tâche par module, donc des bandes
        # homonymes. Elles sont nommées par le nom d'hôte de leur URL.
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
