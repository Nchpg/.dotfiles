{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;

  refusParMinute = 20;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      (lib.mkIf authelia.enable {
        services.authelia.instances.main.settings.telemetry.metrics = {
          enabled = true;
          address = "tcp://127.0.0.1:${toString ports.autheliaMetrics}";
        };

        # Seulement le Redis d'Authelia : le groupe de celui de Nextcloud donnerait accès aux données.
        services.prometheus.exporters.redis = helpers.mkLocalExporter ports.redis // {
          extraFlags = [ "-redis.addr unix:///run/redis-authelia/redis.sock" ];
        };

        # Sans ce groupe l'exporteur publie `redis_up 0`, soit la panne qu'il doit détecter.
        systemd.services.prometheus-redis-exporter.serviceConfig.SupplementaryGroups = [
          "redis-authelia"
        ];

        systemSettings.monitoring.internal.scrapeJobs = {
          authelia = helpers.localJob "authelia" ports.autheliaMetrics // {
            metric_relabel_configs = helpers.suffixeTotal "authelia_authz|authelia_request";
          };
          redis = helpers.localJob "redis" ports.redis;
        };
      })

      {
        systemSettings.monitoring.internal = {
          # Seuil : base de 2 refus/min (les sondes `http_authelia` elles-mêmes), maximum observé 2,44.
          alertRules.PortailRefusEnRafale = {
            alert = "PortailRefusEnRafale";
            expr = "sum(rate(authelia_authz_total{code!=\"200\"}[5m])) * 60 > ${toString refusParMinute}";
            for = "10m";
            labels.severity = "critical";
            annotations.summary = "{{ $value | printf \"%.0f\" }} refus par minute sur le portail, contre 2 en temps normal : quelqu'un insiste sur la seule porte ouverte à internet.";
          };

          # `authelia_authz` et non `authelia_authn_total` (inexistant tant que personne ne s'est connecté).
          panels.authelia = mkTs {
            id = 26;
            title = "Authelia : requêtes filtrées par minute";
            unit = "short";
            description = "La ligne de base est de 2 refus/min : ce sont les sondes blackbox elles-mêmes, qui reçoivent le 302 qu'elles attendent. L'alerte `PortailRefusEnRafale` se déclenche à ${toString refusParMinute}.";
            decimals = 0;
            targets = [
              {
                expr = "sum(rate(authelia_authz_total{code=\"200\"}[5m])) * 60";
                legend = "laissées passer (bypass)";
              }
              {
                expr = "sum(rate(authelia_authz_total{code!=\"200\"}[5m])) * 60";
                legend = "renvoyées au portail";
              }
            ];
          };
        };
      }
    ]
  );
}
