{
  config,
  lib,
  ...
}:

# La validation du build ne compile pas le VRL : une erreur n'apparaît qu'au démarrage (status=78/CONFIG).
# Test : `echo '{"message":"…"}' | vector vrl -p vector/nginx.vrl -i /dev/stdin` (remplacer `@TZ@`).
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports;
in
{
  config = lib.mkIf (cfg.enable && cfg.logs.enable) {
    services.vector = {
      enable = true;

      # Groupe `systemd-journal` : sans lui Vector démarre sain mais ne lit rien.
      journaldAccess = true;

      settings = {
        data_dir = "/var/lib/vector";

        sources.journal = {
          type = "journald";

          # `false` : sinon les dernières lignes avant un plantage seraient abandonnées au reboot.
          current_boot_only = false;

          exclude_units = cfg.logs.excludeUnits;
        };

        sources.nginx = {
          type = "file";
          include = [
            "/var/log/nginx/access.log"
            "/var/log/nginx/error.log"
          ];
          read_from = "beginning";
        };

        transforms.nginx_normalise = {
          type = "remap";
          inputs = [ "nginx" ];
          source = builtins.replaceStrings [ "@TZ@" ] [ config.time.timeZone ] (
            builtins.readFile ./vector/nginx.vrl
          );
        };

        sources.internes.type = "internal_metrics";

        sinks.metriques = {
          type = "prometheus_exporter";
          inputs = [ "internes" ];
          address = "127.0.0.1:${toString ports.vector}";
        };

        # Normaliser avant d'étiqueter : un champ absent fait perdre l'événement (`_SYSTEMD_UNIT` manque sur le noyau).
        transforms.normalise = {
          type = "remap";
          inputs = [ "journal" ];
          source = builtins.readFile ./vector/journal.vrl;
        };

        sinks.loki = {
          type = "loki";
          inputs = [
            "normalise"
            "nginx_normalise"
          ];
          endpoint = "http://127.0.0.1:${toString ports.loki}";

          encoding.codec = "text";

          # Lots depuis plusieurs unités : refuser le désordre ferait perdre des lignes.
          out_of_order_action = "accept";

          # Cardinalité bornée : chaque combinaison crée un flux Loki.
          labels = {
            unit = "{{ _SYSTEMD_UNIT }}";
            identifier = "{{ SYSLOG_IDENTIFIER }}";
            level = "{{ level }}";
            host = "{{ host }}";
          };
        };
      };
    };

    # `wants` et non `requires` : Loki à terre ne doit pas emporter Vector.
    systemd.services.vector = {
      after = [ "loki.service" ];
      wants = [ "loki.service" ];

      # `mkForce` : le module amont pose une chaîne sous mkIf (pas de fusion). Garder `systemd-journal`.
      serviceConfig.SupplementaryGroups = lib.mkForce [
        "systemd-journal"
        "nginx"
      ];
    };

    systemSettings.monitoring.internal.scrapeJobs.vector =
      cfg.internal.helpers.localJob "vector" ports.vector;

    systemSettings.notify.discord.units = [ "vector" ];
  };
}
