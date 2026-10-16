{ lib, ... }:

let
  internalOpt =
    args:
    lib.mkOption (
      {
        internal = true;
        type = lib.types.attrsOf lib.types.raw;
        default = { };
      }
      // args
    );
in
{
  options.systemSettings.monitoring.internal = {
    ports = internalOpt {
      readOnly = true;
      type = lib.types.attrsOf lib.types.port;
      default = {
        prometheus = 9090;
        alertmanager = 9093;
        node = 9100;
        blackbox = 9115;
        grafana = 3000;
        smartctl = 9633;

        loki = 3100;
        lokiGrpc = 9096;

        # Pas `services.nginx.statusPage` : son vhost sur le port 80 déplacerait le serveur par défaut.
        # Rester dans les 9000 : les apps servent dans les 8000.
        nginxStatus = 9114;
        nginx = 9113;
        phpfpm = 9253;
        wireguardExporter = 9586;
        autheliaMetrics = 9959;
        nextcloudExporter = 9205;

        postgres = 9187;
        redis = 9121;
        dnsmasq = 9153;
        vector = 9598;
      };
    };

    helpers = internalOpt {
      readOnly = true;
      default = rec {
        mkLocalExporter = port: {
          enable = true;
          listenAddress = "127.0.0.1";
          inherit port;
        };

        localTarget = port: [ { targets = [ "127.0.0.1:${toString port}" ]; } ];

        localJob = job_name: port: {
          inherit job_name;
          static_configs = localTarget port;
        };

        # `${"$"}{1}` et non `$1` : Prometheus lirait `$1_total` comme un groupe nommé inexistant.
        # Ne passer que de vrais compteurs (pas `dnsmasq_cachesize`, pas `smartctl_device_attribute`).
        suffixeTotal = noms: [
          {
            source_labels = [ "__name__" ];
            regex = "(${noms})";
            target_label = "__name__";
            replacement = "${"$"}{1}_total";
          }
        ];
      };
    };

    q = internalOpt {
      readOnly = true;
      default = {
        alertesActives = ''ALERTS{alertstate="firing", alertname!="Watchdog"}'';

        parCible = expr: ''label_replace(${expr}, "cible", "$1", "instance", "https?://([^/]+).*")'';
      };
    };

    scrapeJobs = internalOpt { };

    # `inhibits = { alertname; equal; }` sur une règle critique est retiré avant l'écriture des règles.
    alertRules = internalOpt { };

    lokiRuleGroups = internalOpt { };

    panels = internalOpt { };
  };
}
