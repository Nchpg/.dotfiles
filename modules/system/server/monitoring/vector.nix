{
  config,
  lib,
  ...
}:

# Vector : lit le journal et le pousse dans Loki. Promtail, qui tenait ce rôle
# historiquement, est en fin de vie depuis mars 2026 et a disparu de nixpkgs ;
# Vector le remplace ici plutôt qu'Alloy parce que sa configuration est de la
# DONNÉE — des attrsets Nix rendus en TOML — là où Alloy demande d'embarquer un
# fichier écrit dans son propre langage, que rien dans ce dépôt ne saurait
# relire.
#
# NE COMPTE PAS SUR LA VALIDATION AU BUILD POUR LE VRL. Le module amont lance
# bien `vector validate --no-environment` sur le TOML produit, mais ce drapeau
# ne construit pas la topologie : les programmes VRL ne sont jamais COMPILÉS.
# Une condition que le langage refuse passe donc le rebuild, et c'est l'unité
# qui meurt au démarrage en « status=78/CONFIG », après le basculement —
# c'est-à-dire au pire moment, quand plus rien ne peut refuser le changement.
# Constaté le 20 août 2026.
#
# CE QUI VALIDE VRAIMENT, à passer avant tout déploiement touchant un `.vrl` de
# ce dossier :
#
#   echo '{"message":"…"}' | vector vrl -p vector/nginx.vrl -i /dev/stdin
#
# Il compile le programme ET le fait tourner sur un événement, donc il attrape
# aussi bien la syntaxe que le résultat. Une ligne de journal réelle copiée
# depuis Loki suffit à faire un cas de test. (`nginx.vrl` contient `@TZ@`, que
# ce module remplace par `time.timeZone` : le remplacer aussi pour le test.)
#
# Loki, lui, vérifie réellement sa configuration au build.
let
  cfg = config.systemSettings.monitoring;
  inherit (cfg.internal) ports;
in
{
  config = lib.mkIf (cfg.enable && cfg.logs.enable) {
    services.vector = {
      enable = true;

      # Fait entrer l'unité dans le groupe `systemd-journal`. C'est LE réglage
      # sans lequel tout le reste est inerte : Vector démarrerait, se déclarerait
      # en bonne santé, et ne lirait rien — le mode d'échec le plus déroutant de
      # cette brique.
      journaldAccess = true;

      settings = {
        # Signet de lecture du journal. Le module amont pose `StateDirectory`,
        # donc ce chemin existe et survit aux redémarrages : Vector reprend où il
        # s'était arrêté, sans trou ni doublon. C'est aussi ce qui rend le
        # redémarrage d'un rebuild indolore.
        data_dir = "/var/lib/vector";

        sources.journal = {
          type = "journald";

          # `false`, contre le défaut de Vector : limité au démarrage courant, il
          # abandonnerait à chaque redémarrage de la machine tout ce qui n'avait
          # pas encore été expédié du démarrage précédent — c'est-à-dire
          # exactement les dernières lignes avant un plantage, les seules qu'on
          # voudra lire.
          current_boot_only = false;

          exclude_units = cfg.logs.excludeUnits;
        };

        # LES JOURNAUX D'ACCÈS DE NGINX, qui ne sont PAS dans journald : nginx
        # écrit dans des fichiers, et journald ne les voit pas. Sans cette
        # source, la réponse à « d'où vient ce pic de requêtes ? » demandait un
        # `sudo grep` sur la machine.
        #
        # `error.log` avec, et il vaut au moins autant : c'est là que nginx dit
        # qu'un amont ne répond plus, qu'une poignée de main TLS a échoué ou
        # qu'un certificat manque — des pannes que le journal d'accès ne montre
        # que par leur conséquence.
        #
        # DEPUIS LE DÉBUT DU FICHIER au premier démarrage : Loki accepte les
        # entrées anciennes (cf. `reject_old_samples`), donc on récupère
        # l'historique de la semaine en cours plutôt que de partir de zéro. La
        # rotation est hebdomadaire, le volume rattrapé reste de l'ordre de la
        # dizaine de mégaoctets.
        sources.nginx = {
          type = "file";
          include = [
            "/var/log/nginx/access.log"
            "/var/log/nginx/error.log"
          ];
          read_from = "beginning";
        };

        # Horodatage tiré de la ligne, gravité déduite du code de retour (seuil
        # à 500 : un 4xx est une erreur du CLIENT), et reclassement des 502 que
        # provoque un onglet Grafana ouvert pendant un redémarrage. Le
        # raisonnement est dans le fichier.
        #
        # Seule interpolation : le fuseau du journal d'ERREURS, qui n'a que
        # l'heure locale. Il vient de `time.timeZone`, et `parse_timestamp`
        # s'appuie sur la base tz — donc juste aussi au changement d'heure.
        transforms.nginx_normalise = {
          type = "remap";
          inputs = [ "nginx" ];
          source = builtins.replaceStrings [ "@TZ@" ] [ config.time.timeZone ] (
            builtins.readFile ./vector/nginx.vrl
          );
        };

        # SES PROPRES COMPTEURS, sans quoi la brique qui collecte le journal est
        # la seule chose de cette machine que personne ne regarde.
        #
        # Le mode d'échec qu'on ferme ici : Vector qui TOURNE sans plus rien
        # expédier. L'unité reste `active`, `notify.discord` n'a donc rien à
        # signaler, Loki répond parfaitement à des requêtes sur des journaux qui
        # ont cessé d'arriver, et la page reste fonctionnelle et vide — ce qui
        # ressemble trait pour trait à une machine calme. Les règles qui lisent
        # ces compteurs sont dans components/logs.nix.
        sources.internes.type = "internal_metrics";

        sinks.metriques = {
          type = "prometheus_exporter";
          inputs = [ "internes" ];
          address = "127.0.0.1:${toString ports.vector}";
        };

        # NORMALISATION AVANT ÉTIQUETAGE, et ce n'est pas cosmétique. Les
        # étiquettes du puits sont des gabarits : un champ absent rend le gabarit
        # irréalisable et l'événement est PERDU, sans que rien ne le dise.
        #
        # Or `_SYSTEMD_UNIT` manque sur tout ce qui ne vient pas d'une unité — les
        # messages du NOYAU en particulier, c'est-à-dire les disques, la mémoire
        # et le réseau. Les lignes les plus précieuses du journal sont justement
        # celles qui seraient tombées.
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

          # Le MESSAGE seul, pas l'événement complet en JSON. Ce qu'on vient lire
          # dans Grafana est une ligne de journal telle que `journalctl`
          # l'afficherait ; le reste des champs devient des étiquettes ci-dessous,
          # ou n'a aucun intérêt.
          encoding.codec = "text";

          # Loki 3 accepte le désordre dans une fenêtre donnée, et Vector expédie
          # par lots depuis plusieurs unités à la fois : refuser ferait perdre des
          # lignes pour une question d'ordre d'arrivée.
          out_of_order_action = "accept";

          # PEU D'ÉTIQUETTES, ET AUCUNE QUI VARIE BEAUCOUP. C'est la règle
          # cardinale de Loki : chaque combinaison distincte de valeurs crée un
          # FLUX séparé, avec son propre index et ses propres fichiers. Une
          # étiquette portant un identifiant de processus ou un horodatage en
          # fabriquerait des milliers et mettrait Loki à genoux.
          #
          # Les quatre retenues sont bornées : quelques dizaines d'unités, autant
          # d'identifiants, huit gravités, un hôte. Tout le reste — le contenu du
          # message, le PID, le fichier source — se cherche en plein texte, ce que
          # Loki fait très bien sans index.
          labels = {
            unit = "{{ _SYSTEMD_UNIT }}";
            identifier = "{{ SYSLOG_IDENTIFIER }}";
            level = "{{ level }}";
            host = "{{ host }}";
          };
        };
      };
    };

    # ORDONNER VECTOR APRÈS LOKI. Vector réessaie et met en tampon, donc
    # démarrer en premier ne perd rien — mais il passe alors ses premières
    # secondes à échouer à se connecter, à chaque démarrage de la machine. C'est
    # du bruit régulier dans le journal, et c'est le journal de la brique qui
    # collecte le journal.
    #
    # `wants` et non `requires` : Loki à terre plus tard ne doit pas emporter
    # Vector, qui tamponne et reprendra tout seul.
    systemd.services.vector = {
      after = [ "loki.service" ];
      wants = [ "loki.service" ];

      # LES DEUX GROUPES, ET `mkForce` EST OBLIGATOIRE ICI. Le module amont pose
      # `SupplementaryGroups = "systemd-journal"` sous un `mkIf`, une CHAÎNE et
      # non une liste : une seconde définition ne fusionne pas, elle entre en
      # conflit à l'évaluation.
      #
      # D'où l'écrasement — et le piège qu'il crée : `systemd-journal` DOIT
      # rester dans cette liste. L'oublier ne casse rien de visible, Vector
      # démarrerait et se déclarerait en bonne santé en ne lisant plus une seule
      # ligne du journal. Il ne resterait que les accès nginx, donc une page qui
      # a l'air de fonctionner.
      #
      # `nginx` donne la lecture sur /var/log/nginx, qui est en 750 pour ce
      # groupe. Il n'ouvre RIEN d'autre : les certificats appartiennent au
      # groupe `acme`, pas à celui-ci.
      serviceConfig.SupplementaryGroups = lib.mkForce [
        "systemd-journal"
        "nginx"
      ];
    };

    # Vector qui tourne sans plus rien faire : `CibleInjoignable` s'applique à
    # cette cible sans qu'on ait à écrire une règle de plus.
    systemSettings.monitoring.internal.scrapeJobs.vector =
      cfg.internal.helpers.localJob "vector" ports.vector;

    # Vector à terre, Loki répond parfaitement à des requêtes sur des journaux
    # qui ont cessé d'arriver : la page reste fonctionnelle et VIDE, ce qui
    # ressemble à une machine calme.
    systemSettings.notify.discord.units = [ "vector" ];
  };
}
