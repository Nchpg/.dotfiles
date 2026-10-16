{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  notify = config.systemSettings.notify.discord;
  inherit (cfg.internal) ports alertRules;

  # DynamicUser : pas d'`owner` sops possible, d'où LoadCredential.
  amCredentials = "/run/credentials/alertmanager.service";

  # Paires nommées : l'exemple canonique d'Alertmanager (même alertname, gravités différentes) ne s'applique pas.
  seuilsEmboites = lib.concatMap (
    r:
    lib.optional (r ? inhibits) {
      critique = r.alert;
      avertissement = r.inhibits.alertname;
      inherit (r.inhibits) equal;
    }
  ) (lib.attrValues alertRules);

  nomsDeRegles = map (r: r.alert) (lib.attrValues alertRules);
  inhibitionsOrphelines = lib.filter (p: !(lib.elem p.avertissement nomsDeRegles)) seuilsEmboites;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = inhibitionsOrphelines == [ ];
        message = "systemSettings.monitoring : `inhibits` vise une alerte qui n'existe pas : ${
          toString (map (p: "${p.critique} -> ${p.avertissement}") inhibitionsOrphelines)
        }";
      }
    ];

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = ports.alertmanager;

      configuration = {
        route = {
          receiver = "discord";

          group_by = [ "alertname" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";

          # Sans cette route, Watchdog partirait sur Discord toutes les 5 minutes.
          routes = lib.optional cfg.deadManSwitch.enable {
            receiver = "deadman";
            matchers = [ ''alertname="Watchdog"'' ];
            group_wait = "0s";
            group_interval = "1m";
            repeat_interval = cfg.deadManSwitch.interval;
          };
        };

        inhibit_rules = map (p: {
          source_matchers = [ ''alertname="${p.critique}"'' ];
          target_matchers = [ ''alertname="${p.avertissement}"'' ];
          inherit (p) equal;
        }) seuilsEmboites;

        receivers = [
          {
            name = "discord";
            discord_configs = [
              {
                # Config dans le store, lisible de tous : l'URL vient d'un fichier.
                webhook_url_file = "${amCredentials}/discord_webhook";
                send_resolved = true;
                title = ''{{ if eq .Status "firing" }}🔴 {{ .Alerts.Firing | len }} × {{ .CommonLabels.alertname }}{{ else }}🟢 Résolu — {{ .CommonLabels.alertname }}{{ end }}'';
                message = ''
                  {{ range .Alerts -}}
                  **{{ .Labels.severity }}** · `{{ .Labels.instance }}`
                  {{ .Annotations.summary }}
                  {{ end }}
                '';
              }
            ];
          }
        ]
        ++ lib.optional cfg.deadManSwitch.enable {
          name = "deadman";
          webhook_configs = [
            {
              url_file = "${amCredentials}/healthchecks_ping";
              send_resolved = false;
              max_alerts = 1;
            }
          ];
        };
      };
    };

    systemSettings.monitoring.internal.scrapeJobs.alertmanager =
      cfg.internal.helpers.localJob "alertmanager" ports.alertmanager;

    # `restartUnits` : alertmanager ne relit pas ses credentials.
    sops.secrets = lib.mkMerge [
      { ${notify.webhookKey}.restartUnits = [ "alertmanager.service" ]; }

      (lib.mkIf cfg.deadManSwitch.enable {
        ${cfg.deadManSwitch.pingUrlKey} = {
          mode = "0400";
          restartUnits = [ "alertmanager.service" ];
        };
      })
    ];

    systemd.services.alertmanager.serviceConfig.LoadCredential = [
      "discord_webhook:${config.sops.secrets.${notify.webhookKey}.path}"
    ]
    ++ lib.optional cfg.deadManSwitch.enable "healthchecks_ping:${
      config.sops.secrets.${cfg.deadManSwitch.pingUrlKey}.path
    }";

    # Arrêté, il ne route plus l'alerte qui le dirait.
    systemSettings.notify.discord.units = [ "alertmanager" ];
  };
}
