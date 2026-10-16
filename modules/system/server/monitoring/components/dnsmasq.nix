{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  dns = config.systemSettings.dns;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.server.grafana) mkTs;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable && dns.enable) {
    services.prometheus.exporters.dnsmasq = helpers.mkLocalExporter ports.dnsmasq // {
      # `127.0.0.1` et non `localhost` : il se résout d'abord en `::1`, or dnsmasq n'écoute qu'en IPv4.
      dnsmasqListenAddress = "127.0.0.1:53";
    };

    systemSettings.monitoring.internal = {
      scrapeJobs.dnsmasq = helpers.localJob "dnsmasq" ports.dnsmasq // {
        # `cachesize`, `leases` et `auth` sont de vraies jauges : à laisser intacts.
        metric_relabel_configs = helpers.suffixeTotal "dnsmasq_hits|dnsmasq_misses|dnsmasq_insertions|dnsmasq_evictions|dnsmasq_servers_queries|dnsmasq_servers_queries_failed";
      };

      alertRules = {
        # `absent()` car il n'existe pas de `dnsmasq_up`.
        MetriquesDnsmasqAbsentes = {
          alert = "MetriquesDnsmasqAbsentes";
          expr = "absent(dnsmasq_cachesize)";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Aucune métrique DNS de dnsmasq n'arrive : l'exporteur répond mais ne mesure rien.";
        };

        # Sans trafic la division rend NaN, donc aucune série.
        ResolutionDnsEnEchec = {
          alert = "ResolutionDnsEnEchec";
          expr = "rate(dnsmasq_servers_queries_failed_total[15m]) / rate(dnsmasq_servers_queries_total[15m]) > 0.5";
          for = "15m";
          labels.severity = "critical";
          annotations.summary = "Le résolveur amont {{ $labels.server }} échoue sur {{ $value | printf \"%.0f\" }} % des requêtes : dnsmasq répond toujours, mais plus rien d'externe ne se résout.";
        };
      };

      panels.dnsmasq = mkTs {
        id = 39;
        title = "dnsmasq : résolutions par minute";
        unit = "short";
        description = "dnsmasq résout les noms du LAN et du VPN, et le tunnel dépend de lui pour démarrer. Son arrêt casse les noms partout sans faire échouer une seule unité — deux courbes à zéro sont donc un signal, pas un calme.";
        decimals = 0;
        targets = [
          {
            expr = "rate(dnsmasq_hits_total[5m]) * 60";
            legend = "servies par le cache";
          }
          {
            expr = "rate(dnsmasq_misses_total[5m]) * 60";
            legend = "transmises à l'amont";
          }
        ];
      };
    };
  };
}
