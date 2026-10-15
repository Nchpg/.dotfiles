{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# blackbox : ce qu'un client voit en tapant sur une URL — code de retour, temps
# de réponse, expiration du certificat.
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

  # Seuils des alertes sur les certificats, en jours, repris par le panneau.
  #
  # Même seuil d'avertissement que `acme-expiry-check` (cf.
  # modules/system/server/proxy) — 21 jours — pour la même raison : lego
  # renouvelle à 30 jours, alerter plus tôt sonnerait à chaque fenêtre de
  # renouvellement normale.
  certificatJours = {
    avertissement = 21;
    critique = 7;
  };

  # SOCLE COMMUN des sondes HTTP. Les deux modules ne diffèrent que par le code
  # de retour attendu ; tout le reste — la version du protocole, le refus de
  # suivre les redirections, l'exigence de TLS, la famille d'adresses — porte une
  # décision qui doit valoir pour TOUTES les sondes. Deux blocs jumeaux finissent
  # toujours par diverger sur la ligne qu'on a oublié de reporter, et la
  # divergence ne se voit pas.
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

      # NE PAS SUIVRE les redirections, alors que blackbox le fait par défaut.
      # Les suivre menait tout droit à la page de connexion du portail, qui
      # répond 200 : la sonde de `cloud.` validait donc Authelia à la place du
      # service qu'elle était censée surveiller, et serait restée verte avec
      # Nextcloud à terre.
      follow_redirects = false;

      fail_if_not_ssl = true;

      # Pas d'IPv6 sur ce parc (les annonces de routeur sont refusées, cf.
      # modules/system/network) : sans ce réglage la sonde tente d'abord une
      # famille qui ne répond pas et compte l'échec.
      preferred_ip_protocol = "ip4";
      ip_protocol_fallback = false;
    };
  };

  blackboxConfig = pkgs-stable.writeText "blackbox.yml" (
    builtins.toJSON {
      modules = {
        # Le service répond vraiment. Liste VIDE = le défaut de blackbox, soit
        # 2xx et rien d'autre.
        http_2xx = mkHttpProber [ ];

        # Nom protégé par Authelia, sondé DEPUIS le host. L'adresse source n'est
        # ni celle du VPN ni rien qu'une règle `bypass` reconnaisse, donc le
        # portail répond 302 vers la page de connexion.
        #
        # LE 302 ET RIEN D'AUTRE, et c'est ce qui rend cette sonde utile dans les
        # DEUX SENS. Un 200 sur un nom protégé ne serait pas une bonne nouvelle :
        # il voudrait dire que le portail ne s'interpose plus.
        http_authelia = mkHttpProber [ 302 ];
      };
    }
  );

  probes = lib.attrValues cfg.blackbox.targets;
  probeModules = lib.unique (map (p: p.module) probes);
  urlsFor = m: map (p: p.url) (lib.filter (p: p.module == m) probes);

  # Une tâche de collecte par module blackbox employé : le module est un
  # PARAMÈTRE de requête, il ne peut donc pas varier à l'intérieur d'une tâche.
  #
  # Les `relabel_configs` sont la mécanique standard et non négociable de cet
  # exporteur : l'adresse de la cible doit devenir le paramètre `target`, puis
  # l'adresse réellement contactée doit être remplacée par celle de l'exporteur.
  # Sans la troisième règle, Prometheus irait interroger l'URL surveillée
  # elle-même en lui demandant des métriques.
  blackboxJobs = map (m: {
    job_name = "blackbox-${m}";
    metrics_path = "/probe";
    params.module = [ m ];
    # Moins souvent que le reste : une sonde ouvre une vraie connexion TLS vers
    # un service tiers, on ne le fait pas toutes les trente secondes.
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
      # CONDITIONNÉ À L'EXISTENCE DE CIBLES, et pas seulement par économie.
      #
      # Le point d'entrée `/probe` de cet exporteur prend l'URL à sonder en
      # PARAMÈTRE : quiconque peut lui parler fait émettre à cette machine une
      # requête HTTP vers la destination de son choix. C'est un relais de
      # requêtes en bonne et due forme. Il n'écoute que sur la boucle locale,
      # donc ça suppose déjà un accès à la machine — raison de plus pour ne pas
      # le faire tourner quand aucune sonde n'est déclarée.
      (lib.mkIf (cfg.blackbox.targets != { }) {
        services.prometheus.exporters.blackbox = helpers.mkLocalExporter ports.blackbox // {
          configFile = blackboxConfig;
        };

        systemSettings.monitoring.internal.scrapeJobs.blackbox = blackboxJobs;

        # Blackbox porte toutes les sondes : sa panne les rend muettes, ce qui
        # vaut d'être connu tout de suite, sans attendre `CibleInjoignable`.
        systemSettings.notify.discord.units = [ "prometheus-blackbox-exporter" ];
      })

      # Règles et panneaux présents même sans cible : sans sonde, leurs
      # métriques n'existent pas, les règles ne s'évaluent sur rien et les
      # panneaux restent vides (« Sondes en échec » affiche 0).
      {
        systemSettings.monitoring.internal = {
          alertRules = {
            SondeEnEchec = {
              alert = "SondeEnEchec";
              expr = "probe_success == 0";
              for = "5m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.instance }} ne répond pas comme attendu.";
              # Une sonde qui échoue est aussi comptée LENTE : elle échoue le
              # plus souvent par expiration du délai, à dix secondes, donc bien
              # au-delà des cinq de `SondeLente`.
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

            # DOUBLON ASSUMÉ avec `acme-expiry-check` (cf.
            # modules/system/server/proxy), et les deux méritent d'exister : la
            # sonde du proxy vérifie le certificat servi sur la boucle locale et
            # n'a besoin de rien d'autre que d'openssl, celle-ci passe par le
            # même chemin qu'un vrai client et garde un historique. Si l'une des
            # deux tombe, l'autre couvre.
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

            # LE NOM D'HÔTE ET NON L'URL ENTIÈRE, et c'est la légende à droite
            # qui l'impose : Grafana lui accorde jusqu'à 60 % de la largeur du
            # panneau, et une URL complète de sonde fait près de cinquante
            # caractères. Le chemin sondé ne se perd pas : il est écrit dans
            # `blackbox.targets`, et l'infobulle porte l'`instance` complète.
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

              # `short` ET SURTOUT PAS `d`, qui semble pourtant l'unité juste.
              # Les unités de TEMPS de Grafana changent d'échelle toutes seules :
              # 89 jours s'affichent « 12.7 week », sur des seuils écrits en
              # jours dans les règles d'alerte. Le titre porte déjà l'unité.
              unit = "short";
              decimals = 0;
              description = "En dents de scie : lego renouvelle à 30 jours restants, donc la courbe redescend de 90 à 30 puis remonte. C'est une dent qui n'est PAS remontée qui doit inquiéter.";
              # Les seuils exacts des deux alertes, tracés en référence : ils
              # disent d'un coup d'œil si la dent en cours est normale ou si le
              # renouvellement a cessé de se faire.
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
