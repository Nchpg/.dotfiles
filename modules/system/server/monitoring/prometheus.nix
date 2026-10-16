{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports scrapeJobs alertRules;

  ordreCollecte = [
    "prometheus"
    "node"
    "alertmanager"
    "smartctl"
    "cloudflared"
    "nginx"
    "php-fpm"
    "authelia"
    "wireguard"
    "nextcloud"
    "loki"
    "vector"
    "postgres"
    "redis"
    "dnsmasq"
    "blackbox"
    "comin"
  ];

  groupes = [
    {
      name = "host";
      rules = [
        "CibleInjoignable"
        "DisqueBientotPlein"
        "DisquePresquePlein"
        "DisquePleinEnTroisJours"
        "InodesEpuises"
        "SystemeDeFichiersEnLectureSeule"
        "MemoireFaible"
        "SwapSollicite"
        "ProcessusTuePourMemoire"
        "ChargeElevee"
        "UniteSystemdEnEchec"
        "ServiceRedemarreEnBoucle"
        "TableDeConnexionsPresquePleine"
        "HorlogeDerive"
        "MachineTropChaude"
        "TimerNeSeDeclenchePlus"
        "TunnelCloudflareCoupe"
        "TunnelCloudflareDegrade"
      ];
    }
    {
      name = "sondes";
      rules = [
        "SondeEnEchec"
        "SondeLente"
        "CertificatBientotExpire"
        "CertificatExpireImminent"
      ];
    }
    {
      name = "disques";
      rules = [
        "DisqueSmartEnEchec"
        "DisqueAvertissementCritique"
        "DisqueReserveEpuisee"
        "DisqueErreursDeMedia"
        "DisqueUsureElevee"
        "DisqueUsureEleveeAta"
        "DisqueSecteursIllisibles"
        "DisqueSecteursEnAttente"
        "DisqueBlocsRealloues"
        "DisqueTropChaud"
        "DisqueLiaisonSataDegradee"
      ];
    }
    {
      name = "applications";
      rules = [
        "PortailRefusEnRafale"
        "PoolPhpSature"
        "SondeApplicativeAveugle"
        "BaseDeDonneesInjoignable"
        "MetriquesDnsmasqAbsentes"
        "ResolutionDnsEnEchec"
        "MetriquesNextcloudAveugles"
      ];
    }
    {
      name = "deploiement";
      rules = [
        "DeploiementEnEchec"
        "DepotInjoignable"
        "DeploiementSuspendu"
        "RedemarrageEnAttente"
      ];
    }
    {
      name = "meta";
      rules = [
        "Watchdog"
        "AlertmanagerNEnvoiePlus"
        "EvaluationDeReglesEnEchec"
        "CollecteDeJournauxEnErreur"
        "CollecteDeJournauxArretee"
        "EvaluationDeReglesLokiEnEchec"
      ];
    }
  ];

  reglesRangees = lib.concatMap (g: g.rules) groupes;

  groupesProduits = lib.filter (g: g.rules != [ ]) (
    map (g: {
      inherit (g) name;
      rules = map (k: removeAttrs alertRules.${k} [ "inhibits" ]) (
        lib.filter (k: alertRules ? ${k}) g.rules
      );
    }) groupes
  );
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.subtractLists ordreCollecte (lib.attrNames scrapeJobs) == [ ];
        message = "systemSettings.monitoring : tâche(s) de collecte absente(s) de `ordreCollecte` (prometheus.nix), donc jamais collectée(s) : ${toString (lib.subtractLists ordreCollecte (lib.attrNames scrapeJobs))}";
      }
      {
        assertion = lib.subtractLists reglesRangees (lib.attrNames alertRules) == [ ];
        message = "systemSettings.monitoring : règle(s) d'alerte rangée(s) dans aucun groupe (prometheus.nix), donc jamais évaluée(s) : ${toString (lib.subtractLists reglesRangees (lib.attrNames alertRules))}";
      }
    ];

    services.prometheus = {
      enable = true;
      # Interface sans authentification : Grafana, derrière le portail, sert de façade.
      listenAddress = "127.0.0.1";
      port = ports.prometheus;
      retentionTime = cfg.retention;

      globalConfig = {
        scrape_interval = cfg.scrapeInterval;
        evaluation_interval = cfg.scrapeInterval;
      };

      rules = [ (builtins.toJSON { groups = groupesProduits; }) ];

      alertmanagers = [
        { static_configs = cfg.internal.helpers.localTarget ports.alertmanager; }
      ];

      scrapeConfigs = lib.concatMap (n: lib.toList (scrapeJobs.${n} or [ ])) ordreCollecte;
    };

    systemSettings.monitoring.internal.scrapeJobs.prometheus =
      cfg.internal.helpers.localJob "prometheus" ports.prometheus;

    # Arrêté, il n'évalue plus la règle qui le dirait.
    systemSettings.notify.discord.units = [ "prometheus" ];
  };
}
