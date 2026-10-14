{
  config,
  lib,
  myLib,
  ...
}:

# Authelia — le portail, seule porte ouverte à internet — et son Redis.
let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  inherit (cfg.internal) ports helpers;
  inherit (myLib.grafana) mkTs;

  # Refus par minute au-delà desquels `PortailRefusEnRafale` se déclenche,
  # repris par la description du panneau.
  refusParMinute = 20;
in
{
  config = lib.mkIf (cfg.enable && cfg.apps.enable) (
    lib.mkMerge [
      (lib.mkIf authelia.enable {
        # Authelia expose ses propres métriques, sans exporteur intermédiaire :
        # le nombre d'authentifications RÉUSSIES et REFUSÉES, que rien d'autre
        # ne voit. Une sonde blackbox constate que le portail répond, pas qu'il
        # laisse encore entrer quelqu'un.
        services.authelia.instances.main.settings.telemetry.metrics = {
          enabled = true;
          address = "tcp://127.0.0.1:${toString ports.autheliaMetrics}";
        };

        # UNE SEULE DES DEUX INSTANCES REDIS, celle d'Authelia, et c'est un choix
        # qu'il faut lire avant de vouloir le compléter.
        #
        # Les deux sockets sont en 660 : les atteindre suppose d'appartenir au
        # groupe propriétaire. Pour Authelia c'est `redis-authelia`, un groupe
        # dédié qui ne possède rien d'autre que l'état de ce Redis — l'y faire
        # entrer n'ouvre rien. Pour Nextcloud c'est le groupe `nextcloud`, celui
        # du service lui-même : y faire entrer un exporteur de métriques lui
        # donnerait accès à tout ce que Nextcloud rend lisible à son groupe,
        # c'est-à-dire aux données.
        #
        # Ce qu'on perd sur l'instance Nextcloud : la saturation mémoire de son
        # cache, dont l'effet — une instance qui rame — se voit par
        # `PoolPhpSature` et par le temps de réponse de la sonde.
        services.prometheus.exporters.redis = helpers.mkLocalExporter ports.redis // {
          extraFlags = [ "-redis.addr unix:///run/redis-authelia/redis.sock" ];
        };

        # LE GROUPE QUI OUVRE LE SOCKET REDIS, et rien d'autre. Sans cette ligne
        # l'exporteur démarre, se déclare en bonne santé et publie `redis_up 0`
        # — c'est-à-dire qu'il annonce exactement la panne qu'il est censé
        # détecter, le pire des faux positifs.
        systemd.services.prometheus-redis-exporter.serviceConfig.SupplementaryGroups = [
          "redis-authelia"
        ];

        systemSettings.monitoring.internal.scrapeJobs = {
          authelia = helpers.localJob "authelia" ports.autheliaMetrics // {
            # Authelia publie ses deux compteurs sans le suffixe. Cf.
            # `suffixeTotal`.
            metric_relabel_configs = helpers.suffixeTotal "authelia_authz|authelia_request";
          };
          redis = helpers.localJob "redis" ports.redis;
        };
      })

      {
        systemSettings.monitoring.internal = {
          # LE PORTAIL EST LA PORTE D'ENTRÉE PUBLIQUE. C'est la seule surface du
          # montage qu'un inconnu peut attaquer sans clé WireGuard : le coffre est
          # derrière le VPN, SSH est sur un port décalé, mais le portail répond à
          # tout internet par construction.
          #
          # SEUIL MESURÉ et non supposé. La ligne de base de cette machine est
          # remarquablement stable : 2 refus/min sur 5 min, sur 1 h et sur 24 h,
          # avec un maximum observé à 2,44. Ces deux-là sont les PROPRES sondes
          # — `http_authelia` interroge deux noms protégés chaque minute et reçoit
          # deux 302, comptés comme des refus. Vingt est dix fois la normale :
          # aucune chance de sonner pour du bruit, et impossible de rater une
          # campagne de bourrage d'identifiants, qui se compte en centaines.
          #
          # `code != "200"` plutôt qu'un code précis : un refus est un refus,
          # qu'Authelia réponde 401 sur une session absente ou 403 sur une règle.
          alertRules.PortailRefusEnRafale = {
            alert = "PortailRefusEnRafale";
            expr = "sum(rate(authelia_authz_total{code!=\"200\"}[5m])) * 60 > ${toString refusParMinute}";
            for = "10m";
            labels.severity = "critical";
            annotations.summary = "{{ $value | printf \"%.0f\" }} refus par minute sur le portail, contre 2 en temps normal : quelqu'un insiste sur la seule porte ouverte à internet.";
          };

          # `authelia_authz` et NON `authelia_authn_total` : ce dernier ne compte
          # que les saisies d'identifiants, donc il n'existe pas tant que
          # personne ne s'est connecté depuis le dernier démarrage — un panneau
          # vide la plupart du temps. `authz` compte les DÉCISIONS
          # d'autorisation, à chaque requête, et c'est le flux continu qu'on veut
          # voir.
          #
          # PAR MINUTE, d'où le `* 60` : `rate()` produit un taux PAR SECONDE, et
          # sur une machine familiale ça donne des valeurs comme 0,41. Le calcul
          # reste fait sur une fenêtre de 5 minutes — c'est le lissage, pas
          # l'unité.
          #
          # DEUX SÉRIES SEULEMENT, ET C'EST UNE LIMITE DE LA SOURCE. Authelia
          # n'expose sur `authz` que le label `code` — rien sur la règle qui a
          # tranché. Impossible de distinguer ici une session valide d'un
          # `bypass` : les deux comptent 200. Mais un `bypass` ne produit JAMAIS
          # de 401, donc la courbe des renvois au portail est pure, et c'est
          # elle qui porte le signal.
          panels.authelia = mkTs {
            id = 26;
            title = "Authelia : requêtes filtrées par minute";
            unit = "short";
            description = "La ligne de base est de 2 refus/min : ce sont les sondes blackbox elles-mêmes, qui reçoivent le 302 qu'elles attendent. L'alerte `PortailRefusEnRafale` se déclenche à ${toString refusParMinute}.";
            decimals = 0;
            targets = [
              {
                expr = "sum(rate(authelia_authz_total{code=\"200\"}[5m])) * 60";
                # « bypass » et non « contournement » : c'est le mot qu'emploie
                # la politique d'Authelia elle-même (`policy: bypass`). La
                # légende ne nomme que le cas le plus fréquent, alors que ce
                # compteur additionne aussi les sessions valides — la source ne
                # les distingue pas.
                legend = "laissées passer (bypass)";
              }
              {
                expr = "sum(rate(authelia_authz_total{code!=\"200\"}[5m])) * 60";
                legend = "renvoyées au portail";
              }
            ];
          };
        };
      }
    ]
  );
}
