{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Loki : le pendant de Prometheus pour le texte. Même posture — boucle locale,
# aucun port ouvert, la façade est Grafana derrière le portail.
#
# BINAIRE UNIQUE, et c'est le seul mode qui ait un sens ici. Loki se déploie
# d'ordinaire en composants séparés qui se parlent par un anneau de hachage ;
# sur une machine, cet anneau tient en mémoire (`inmemory`) avec un seul
# membre. Les valeurs ci-dessous ne sont donc pas des réglages de performance,
# ce sont les valeurs qui désactivent la distribution.
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports lokiRuleGroups;

  # Ordre des groupes de règles du ruler (déposés par components/logs.nix).
  ordreGroupes = [
    "coffre"
    "acces"
    "noyau"
  ];

  # LE RULER EST MONTÉ DÈS QU'UN GROUPE EXISTE, chacun suivant le service qu'il
  # regarde. Le conditionner à l'un d'eux en particulier — c'était le cas avec
  # `kernelAlerts` — ferait qu'en couper un retire le ruler entier, donc
  # emporte aussi les règles des autres : elles resteraient écrites dans le
  # store, personne ne les chargerait, et rien ne le dirait.
  lokiRuler = lokiRuleGroups != { };

  # Règles d'alerte évaluées par le ruler de Loki.
  #
  # LE SOUS-DOSSIER `fake` N'EST PAS UNE PLAISANTERIE, c'est la seule chose à
  # savoir de ce bloc : le stockage local du ruler range les règles PAR
  # LOCATAIRE, et `fake` est le nom que Loki donne au locataire unique quand
  # `auth_enabled` est faux. Un fichier posé à la racine du répertoire est
  # ignoré EN SILENCE — le ruler démarre, ne charge rien, et ne s'en plaint
  # jamais.
  lokiRules = pkgs-stable.linkFarm "loki-rules" [
    {
      name = "fake/rules.yaml";
      # JSON, qui est du YAML valide — même procédé que pour les tableaux de
      # bord Grafana et les checks Datadog.
      path = pkgs-stable.writeText "rules.yaml" (
        builtins.toJSON {
          groups = map (n: lokiRuleGroups.${n}) (lib.filter (n: lokiRuleGroups ? ${n}) ordreGroupes);
        }
      );
    }
  ];
in
{
  config = lib.mkIf (cfg.enable && cfg.logs.enable) {
    assertions = [
      {
        assertion = lib.subtractLists ordreGroupes (lib.attrNames lokiRuleGroups) == [ ];
        message = "systemSettings.monitoring : groupe(s) de règles Loki absent(s) de `ordreGroupes` (loki.nix), donc jamais évalué(s) : ${toString (lib.subtractLists ordreGroupes (lib.attrNames lokiRuleGroups))}";
      }
    ];

    services.loki = {
      enable = true;

      configuration = {
        # Pas de multi-locataire : il n'y a qu'une machine et qu'un lecteur.
        # Laissé à `true`, Loki exigerait un en-tête `X-Scope-OrgID` sur chaque
        # requête, y compris celles de Grafana.
        auth_enabled = false;

        # PHONE HOME COUPÉ. Loki envoie par défaut un rapport d'usage anonyme à
        # Grafana Labs. Rien de sensible n'y passe, mais une machine de la maison
        # n'a pas à ouvrir de connexion sortante que personne n'a demandée.
        analytics.reporting_enabled = false;

        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = ports.loki;

          # Inutilisé en binaire unique (cf. les ports, internal.nix), mais Loki
          # l'ouvre quand même : on le fixe sur la boucle locale plutôt que de le
          # laisser écouter partout sur son défaut.
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = ports.lokiGrpc;

          # Loki est très bavard en `info` — chaque requête de Grafana y passe.
          # Le laisser ainsi ferait de ce service la première source de lignes du
          # journal qu'il est censé collecter, ce qui n'est pas seulement absurde
          # mais BOUCLANT : ses propres traces reviendraient chez lui.
          log_level = "warn";
        };

        common = {
          path_prefix = "/var/lib/loki";
          replication_factor = 1;
          instance_addr = "127.0.0.1";
          ring.kvstore.store = "inmemory";

          storage.filesystem = {
            chunks_directory = "/var/lib/loki/chunks";
            rules_directory = "/var/lib/loki/rules";
          };
        };

        # `from` est la date à partir de laquelle ce schéma s'applique, PAS une
        # date de création : Loki permet d'empiler des schémas pour migrer sans
        # perdre l'ancien. Une seule entrée ici, donc une date passée quelconque
        # suffit — elle doit simplement précéder la première donnée écrite.
        #
        # tsdb + v13 : le couple courant de Loki 3. Les schémas antérieurs
        # marchent encore et sont des culs-de-sac.
        schema_config.configs = [
          {
            from = "2026-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];

        limits_config = {
          retention_period = cfg.logs.retention;

          # ACCEPTER LES ENTRÉES ANCIENNES, contrairement au défaut de Loki qui
          # rejette au-delà d'une semaine. Sans ça, le TOUT PREMIER démarrage
          # produit une rafale de rejets : Vector part du début du journal
          # existant, et tout ce qui dépasse une semaine revient en erreur. Des
          # centaines d'erreurs au premier démarrage, sur un composant dont on
          # veut pouvoir lire le journal, c'est la meilleure façon d'apprendre à
          # ne plus le regarder.
          #
          # Ça n'ouvre pas la porte à un stockage sans fin : le compacteur
          # ci-dessous efface tout ce qui dépasse la rétention à son prochain
          # passage. On accepte, puis on élague — au lieu de refuser bruyamment.
          reject_old_samples = false;

          # Alimente l'histogramme de volume au-dessus des journaux dans Grafana,
          # celui qui montre d'un coup d'œil à quel moment ça s'est mis à parler.
          volume_enabled = true;
        };

        ruler = lib.mkIf lokiRuler {
          storage = {
            type = "local";
            local.directory = lokiRules;
          };

          # Répertoire de TRAVAIL du ruler, distinct des règles elles-mêmes qui
          # viennent du store en lecture seule. Loki y écrit son état
          # d'évaluation, il lui faut donc un chemin inscriptible.
          rule_path = "/var/lib/loki/ruler";

          alertmanager_url = "http://127.0.0.1:${toString ports.alertmanager}";

          # LA LIGNE SANS LAQUELLE AUCUNE ALERTE N'ARRIVE, et rien ne le dirait.
          # Le défaut de Loki est `false`, ce qui le fait poster sur
          # `/api/v1/alerts` — API que Prometheus a RETIRÉE. Mesuré sur cette
          # machine, Alertmanager 0.31.1 y répond « 410 Gone » quand
          # `/api/v2/alerts` répond 200.
          #
          # Le mode d'échec est le pire qui soit pour une chaîne d'alerte : le
          # ruler évalue correctement, déclenche, poste, échoue, et tout le
          # monde a l'air en bonne santé. On ne s'en apercevrait qu'en
          # constatant l'absence d'une alerte attendue — c'est-à-dire jamais,
          # puisque c'est le silence qu'on espère.
          enable_alertmanager_v2 = true;

          ring.kvstore.store = "inmemory";

          # Aucune API de gestion des règles : elles viennent du dépôt, il n'y a
          # rien à créer depuis l'extérieur.
          enable_api = false;
        };

        # SANS CE BLOC, `retention_period` NE FAIT RIEN. Loki l'accepte, ne s'en
        # plaint jamais, et conserve tout indéfiniment — c'est le compacteur qui
        # applique la rétention, et il ne le fait que si on le lui dit
        # explicitement. La panne se découvre le jour où le disque est plein.
        compactor = {
          working_directory = "/var/lib/loki/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
      };
    };

    systemSettings.monitoring.internal = {
      # Loki qui tourne sans plus rien faire : `CibleInjoignable` s'applique à
      # cette cible sans qu'on ait à écrire une règle de plus.
      scrapeJobs.loki = cfg.internal.helpers.localJob "loki" ports.loki;

      # LE MÊME CONTRÔLE QUE `EvaluationDeReglesEnEchec`, POUR L'AUTRE MOTEUR DE
      # RÈGLES : depuis que Loki évalue les siennes, il existe un SECOND endroit
      # où une règle peut cesser de s'évaluer sans que personne ne le sache.
      #
      # Elle existe dès qu'un ruler tourne, quelle que soit la règle qui l'a
      # fait naître.
      #
      # Nom de métrique RELEVÉ sur le `/metrics` de Loki en fonctionnement, pas
      # supposé : `loki_prometheus_rule_evaluation_failures_total`, étiqueté par
      # `rule_group` et par `user`.
      alertRules.EvaluationDeReglesLokiEnEchec = lib.mkIf lokiRuler {
        alert = "EvaluationDeReglesLokiEnEchec";
        expr = "increase(loki_prometheus_rule_evaluation_failures_total[1h]) > 0";
        for = "10m";
        labels.severity = "warning";
        annotations.summary = "Loki n'évalue plus ses règles ({{ $labels.rule_group }}) : l'alerte sur les erreurs disque du noyau ne protège plus de rien.";
      };
    };

    # Loki à terre, Vector tamponne en silence : rien d'autre ne le signale.
    systemSettings.notify.discord.units = [ "loki" ];
  };
}
