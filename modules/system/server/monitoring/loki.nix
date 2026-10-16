{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports lokiRuleGroups;

  ordreGroupes = [
    "coffre"
    "acces"
    "noyau"
  ];

  lokiRuler = lokiRuleGroups != { };

  # `fake` est le locataire unique quand `auth_enabled` est faux : à la racine, le fichier est ignoré.
  lokiRules = pkgs-stable.linkFarm "loki-rules" [
    {
      name = "fake/rules.yaml";
      path = pkgs-stable.writeText "rules.yaml" (
        builtins.toJSON {
          groups = map (n: lokiRuleGroups.${n}) (lib.filter (n: lokiRuleGroups ? ${n}) ordreGroupes);
        }
      );
    }
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.logs.enable) {
    assertions = [
      {
        assertion = lib.subtractLists ordreGroupes (lib.attrNames lokiRuleGroups) == [ ];
        message = "systemSettings.monitoring : groupe(s) de règles Loki absent(s) de `ordreGroupes` (loki.nix), donc jamais évalué(s) : ${toString (lib.subtractLists ordreGroupes (lib.attrNames lokiRuleGroups))}";
      }
    ];

    services.loki = {
      enable = true;

      configuration = {
        # Une machine, un lecteur : sinon Loki exige `X-Scope-OrgID` sur chaque requête.
        auth_enabled = false;

        analytics.reporting_enabled = false;

        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = ports.loki;

          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = ports.lokiGrpc;

          # En `info`, Loki journalise chaque requête de Grafana, puis Vector le rechargerait.
          log_level = "warn";
        };

        common = {
          path_prefix = "/var/lib/loki";
          replication_factor = 1;
          instance_addr = "127.0.0.1";
          ring.kvstore.store = "inmemory";

          storage.filesystem = {
            chunks_directory = "/var/lib/loki/chunks";
            rules_directory = "/var/lib/loki/rules";
          };
        };

        # `from` doit précéder la première donnée écrite.
        schema_config.configs = [
          {
            from = "2026-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];

        limits_config = {
          retention_period = cfg.logs.retention;

          # Vector part du début du journal existant : sinon des centaines de rejets au premier démarrage.
          reject_old_samples = false;

          volume_enabled = true;
        };

        ruler = lib.mkIf lokiRuler {
          storage = {
            type = "local";
            local.directory = lokiRules;
          };

          rule_path = "/var/lib/loki/ruler";

          alertmanager_url = "http://127.0.0.1:${toString ports.alertmanager}";

          # Sans cela Loki poste sur /api/v1/alerts, retiré d'Alertmanager (410 Gone).
          enable_alertmanager_v2 = true;

          ring.kvstore.store = "inmemory";

          enable_api = false;
        };

        # Sans ce bloc, `retention_period` est accepté mais jamais appliqué.
        compactor = {
          working_directory = "/var/lib/loki/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
      };
    };

    systemSettings.monitoring.internal = {
      scrapeJobs.loki = cfg.internal.helpers.localJob "loki" ports.loki;

      alertRules.EvaluationDeReglesLokiEnEchec = lib.mkIf lokiRuler {
        alert = "EvaluationDeReglesLokiEnEchec";
        expr = "increase(loki_prometheus_rule_evaluation_failures_total[1h]) > 0";
        for = "10m";
        labels.severity = "warning";
        annotations.summary = "Loki n'évalue plus ses règles ({{ $labels.rule_group }}) : l'alerte sur les erreurs disque du noyau ne protège plus de rien.";
      };
    };

    systemSettings.notify.discord.units = [ "loki" ];
  };
}
