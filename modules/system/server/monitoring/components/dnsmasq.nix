{
  config,
  lib,
  myLib,
  ...
}:

# dnsmasq, le résolveur de la machine ET la pièce dont dépend le démarrage du
# tunnel (cf. modules/system/server/cloudflared). Son arrêt casse les noms
# internes partout, y compris pour les clients VPN, sans faire échouer une
# seule unité.
let
  cfg = config.systemSettings.monitoring;
  dns = config.systemSettings.dns;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.grafana) mkTs;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable && dns.enable) {
    # dnsmasq ne publie pas de page de métriques : l'exporteur lui pose des
    # questions DNS de classe CHAOS (`cachesize.bind`, `hits.bind`…), ce que
    # dnsmasq répond nativement — `dig @127.0.0.1 CHAOS TXT cachesize.bind`.
    services.prometheus.exporters.dnsmasq = helpers.mkLocalExporter ports.dnsmasq // {
      # `127.0.0.1` ET NON `localhost`, qui est le défaut du module amont :
      # `localhost` se résout d'abord en `::1`, et dnsmasq n'écoute qu'en IPv4
      # sur cette machine (les annonces de routeur IPv6 sont refusées, cf.
      # modules/system/network). L'exporteur échouait alors à chaque collecte :
      #
      #   could not complete scrape: read udp [::1]->[::1]:53: connection refused
      #
      # ET RIEN NE LE DISAIT : l'unité restait `active`, `up` valait 1 puisque
      # l'exporteur répondait bien sur SON port, et il publiait même
      # `dnsmasq_leases 0`, lu dans le fichier de baux. Seule l'ABSENCE de
      # `dnsmasq_cachesize` trahissait la panne — d'où `MetriquesDnsmasqAbsentes`.
      dnsmasqListenAddress = "127.0.0.1:53";
    };

    systemSettings.monitoring.internal = {
      scrapeJobs.dnsmasq = helpers.localJob "dnsmasq" ports.dnsmasq // {
        # COMPTEURS DÉCLARÉS EN JAUGE par cet exporteur, et le panneau des
        # résolutions les lit avec `rate()`. Les compteurs par serveur amont
        # avec, que lit `ResolutionDnsEnEchec`.
        #
        # `cachesize`, `leases` et `auth` restent INTACTS : ce sont de vraies
        # jauges, et la première porte une alerte qui la cherche par son nom.
        # Cf. `suffixeTotal`.
        metric_relabel_configs = helpers.suffixeTotal "dnsmasq_hits|dnsmasq_misses|dnsmasq_insertions|dnsmasq_evictions|dnsmasq_servers_queries|dnsmasq_servers_queries_failed";
      };

      alertRules = {
        # `absent()` ET NON `== 0` : il n'existe pas de `dnsmasq_up` à comparer à
        # zéro, la seule trace de la panne décrite plus haut est que la
        # métrique n'existe pas du tout.
        #
        # CONDITIONNÉE À `dns.enable`, ET C'EST OBLIGATOIRE : une règle
        # `absent()` sur une métrique jamais demandée est VRAIE, donc sonne sans
        # discontinuer, sur toute machine sans résolveur local.
        MetriquesDnsmasqAbsentes = {
          alert = "MetriquesDnsmasqAbsentes";
          expr = "absent(dnsmasq_cachesize)";
          for = "15m";
          labels.severity = "warning";
          annotations.summary = "Aucune métrique DNS de dnsmasq n'arrive : l'exporteur répond mais ne mesure rien.";
        };

        # LA RÉSOLUTION QUI NE RÉSOUT PLUS. La règle ci-dessus vérifie que
        # dnsmasq MESURE ; celle-ci vérifie qu'il RÉUSSIT. Entre les deux, une
        # panne complète : dnsmasq répond, son cache fonctionne, ses métriques
        # arrivent — mais tous ses résolveurs amont échouent, donc plus aucun nom
        # EXTERNE ne se résout.
        #
        # RIEN D'AUTRE NE LE VERRAIT : les sondes blackbox visent des noms que
        # dnsmasq réécrit vers le LAN, `CibleInjoignable` regarde des adresses
        # de bouclage, et les services qui en souffrent échouent sans faire
        # tomber leur unité.
        #
        # SUR LE RAPPORT ET NON SUR UN COMPTE : un timeout isolé ne veut rien
        # dire, c'est la PROPORTION qui distingue l'incident de la panne, et un
        # seuil absolu dépendrait du trafic. La moitié est un seuil
        # volontairement haut, la ligne de base mesurée étant de ZÉRO échec :
        # on veut une panne franche, pas une dégradation fine.
        #
        # AUCUN FAUX POSITIF LA NUIT, vérifié : sans trafic, la division rend
        # `NaN`, et `NaN > 0.5` ne rend aucune série.
        ResolutionDnsEnEchec = {
          alert = "ResolutionDnsEnEchec";
          expr = "rate(dnsmasq_servers_queries_failed_total[15m]) / rate(dnsmasq_servers_queries_total[15m]) > 0.5";
          for = "15m";
          labels.severity = "critical";
          # `server` au singulier, relevé sur le /metrics : il porte l'adresse du
          # résolveur amont, `1.1.1.1#53` par exemple. L'alerte nomme donc celui
          # qui est tombé.
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
            # PAR MINUTE comme les panneaux nginx et Authelia.
            expr = "rate(dnsmasq_hits_total[5m]) * 60";
            legend = "servies par le cache";
          }
          {
            # Ce qui est parti chez le résolveur amont. Le RAPPORT entre les deux
            # courbes est l'information : des ratés qui prennent le pas sur les
            # succès veulent dire un cache trop petit ou vidé en boucle.
            expr = "rate(dnsmasq_misses_total[5m]) * 60";
            legend = "transmises à l'amont";
          }
        ];
      };
    };
  };
}
