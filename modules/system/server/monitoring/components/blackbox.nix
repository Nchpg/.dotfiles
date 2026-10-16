{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports helpers q;
  inherit (myLib.server.grafana)
    mkStat
    mkTs
    steps
    byRegexp
    thresholdLine
    ;

  # Jours. Avertissement à 21 : lego renouvelle à 30, alerter plus tôt sonnerait à chaque renouvellement.
  certificatJours = {
    avertissement = 21;
    critique = 7;
  };

  mkHttpProber = valid_status_codes: {
    prober = "http";
    timeout = "10s";
    http = {
      method = "GET";
      valid_http_versions = [
        "HTTP/1.1"
        "HTTP/2.0"
      ];
      inherit valid_status_codes;

      # Les redirections mènent à la page de connexion du portail (200), qui validerait Authelia à la place du service.
      follow_redirects = false;

      fail_if_not_ssl = true;

      # Pas d'IPv6 sur ce parc : sinon la sonde essaie d'abord une famille qui ne répond pas.
      preferred_ip_protocol = "ip4";
      ip_protocol_fallback = false;
    };
  };

  blackboxConfig = pkgs-stable.writeText "blackbox.yml" (
    builtins.toJSON {
      modules = {
        http_2xx = mkHttpProber [ ];

        # Un 200 serait mauvais signe (le portail ne s'interpose plus).
        http_authelia = mkHttpProber [ 302 ];
      };
    }
  );

  probes = lib.attrValues cfg.blackbox.targets;
  probeModules = lib.unique (map (p: p.module) probes);
  urlsFor = m: map (p: p.url) (lib.filter (p: p.module == m) probes);

  # Une tâche par module (paramètre de requête). Sans la 3e règle de relabel, Prometheus interrogerait l'URL elle-même.
  blackboxJobs = map (m: {
    job_name = "blackbox-${m}";
    metrics_path = "/probe";
    params.module = [ m ];
    scrape_interval = "1m";
    scrape_timeout = "15s";
    static_configs = [ { targets = urlsFor m; } ];
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "__param_target" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "127.0.0.1:${toString ports.blackbox}";
      }
    ];
  }) probeModules;
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # `/probe` est un relais de requêtes HTTP : seulement s'il y a des cibles.
      (lib.mkIf (cfg.blackbox.targets != { }) {
        services.prometheus.exporters.blackbox = helpers.mkLocalExporter ports.blackbox // {
          configFile = blackboxConfig;
        };

        systemSettings.monitoring.internal.scrapeJobs.blackbox = blackboxJobs;

        systemSettings.notify.discord.units = [ "prometheus-blackbox-exporter" ];
      })

      {
        systemSettings.monitoring.internal = {
          alertRules = {
            SondeEnEchec = {
              alert = "SondeEnEchec";
              expr = "probe_success == 0";
              for = "5m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.instance }} ne répond pas comme attendu.";
              inhibits = {
                alertname = "SondeLente";
                equal = [ "instance" ];
              };
            };

            SondeLente = {
              alert = "SondeLente";
              expr = "probe_duration_seconds > 5";
              for = "30m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} répond en {{ $value | printf \"%.1f\" }} s.";
            };

            CertificatBientotExpire = {
              alert = "CertificatBientotExpire";
              expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400 < ${toString certificatJours.avertissement}";
              for = "1h";
              labels.severity = "warning";
              annotations.summary = "Le certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours.";
            };

            CertificatExpireImminent = {
              alert = "CertificatExpireImminent";
              expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400 < ${toString certificatJours.critique}";
              for = "10m";
              labels.severity = "critical";
              annotations.summary = "Le certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours, le renouvellement ne se fait plus.";
              inhibits = {
                alertname = "CertificatBientotExpire";
                equal = [ "instance" ];
              };
            };
          };

          panels = {
            sondesEnEchec = mkStat {
              id = 4;
              title = "Sondes en échec";
              unit = "short";
              description = "Points sondés par une vraie requête HTTP qui ne répondent pas comme attendu. Le détail est dans la section Accès public.";
              expr = "count(probe_success == 0) or vector(0)";
              steps = steps "green" [
                1
                "red"
              ];
            };

            sondesTempsDeReponse = mkTs {
              id = 16;
              title = "Temps de réponse des sondes";
              unit = "s";
              description = "Mesuré depuis le host. ATTENTION : les noms publics sont réécrits par dnsmasq, donc ces sondes tapent sur nginx en direct et ne traversent PAS le tunnel Cloudflare. Elles ne disent rien de la joignabilité depuis internet.";
              targets = [
                {
                  expr = q.parCible "probe_duration_seconds";
                  legend = "{{ cible }}";
                }
              ];
            };

            certificats = mkTs {
              id = 17;
              title = "Certificats : jours restants";
              # `short` et non `d` : Grafana changerait d'échelle (« 12.7 week »), or les seuils sont en jours.
              unit = "short";
              decimals = 0;
              description = "En dents de scie : lego renouvelle à 30 jours restants, donc la courbe redescend de 90 à 30 puis remonte. C'est une dent qui n'est PAS remontée qui doit inquiéter.";
              overrides = [ (thresholdLine (byRegexp "seuil .*")) ];
              targets = [
                {
                  expr = q.parCible "(probe_ssl_earliest_cert_expiry - time()) / 86400";
                  legend = "{{ cible }}";
                }
                {
                  expr = toString certificatJours.avertissement;
                  legend = "seuil d'alerte";
                }
                {
                  expr = toString certificatJours.critique;
                  legend = "seuil critique";
                }
              ];
            };
          };
        };
      }
    ]
  );
}
