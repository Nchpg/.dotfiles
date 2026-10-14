{
  config,
  lib,
  ...
}:

# Prometheus : collecte, historique, et ÉVALUATION DES RÈGLES. C'est lui qui
# décide qu'il y a un problème.
#
# Ce fichier ne déclare ni tâche ni règle : il ramasse celles que les
# composants déposent dans `internal` et fixe leur ORDRE dans le fichier
# produit.
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports scrapeJobs alertRules;

  # Ordre des tâches de collecte. Une entrée absente (composant coupé) est
  # sautée ; une tâche déclarée mais oubliée ici fait échouer l'évaluation.
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
  ];

  # RÈGLES D'ALERTE, par groupe et dans l'ordre où elles s'écrivent. C'est la
  # seule partie de ce module qui décide de quelque chose : Prometheus
  # fraîchement installé collecte en silence et ne dit jamais rien tant que rien
  # n'est écrit ici.
  #
  # Deux réglages portent tout le poids et méritent qu'on y revienne quand une
  # alerte agace : le SEUIL, et surtout le `for`, qui exige que la condition
  # tienne pendant toute la durée. C'est lui qui fait la différence entre une
  # alerte qu'on lit et une alerte qu'on apprend à ignorer.
  #
  # Un groupe sans règle (composant coupé) disparaît du fichier.
  groupes = [
    {
      # components/host.nix, sauf la dernière paire (components/cloudflared.nix).
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
      # components/blackbox.nix
      name = "sondes";
      rules = [
        "SondeEnEchec"
        "SondeLente"
        "CertificatBientotExpire"
        "CertificatExpireImminent"
      ];
    }
    {
      # components/smartctl.nix
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
      # Les exporteurs applicatifs, un composant chacun.
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
      # La surveillance elle-même : components/meta.nix, components/logs.nix
      # (la collecte de journaux) et loki.nix (son ruler).
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
      # Boucle locale : rien n'a besoin de joindre Prometheus depuis le réseau,
      # et son interface d'exploration donne accès à TOUTES les métriques sans
      # la moindre authentification — c'est Grafana, derrière le portail, qui
      # sert de façade.
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

    # Prometheus arrêté n'évalue plus la règle qui dirait qu'il est arrêté : le
    # signalement d'échec d'unité est son SEUL filet.
    systemSettings.notify.discord.units = [ "prometheus" ];
  };
}
