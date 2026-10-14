{
  config,
  lib,
  ...
}:

# Agent Datadog : pousse les métriques de CETTE machine vers l'interface hébergée
# par Datadog, où elles se regardent depuis n'importe quel navigateur — sans
# port ouvert, sans passer par le tunnel, et sans que think ait besoin d'être
# debout pour qu'on consulte ce qu'elle a envoyé.
#
# CE MODULE S'ARRÊTE À L'OFFRE GRATUITE, et toute sa forme vient de là. Datadog
# vend son produit en morceaux, dont un seul est offert :
#
#   - Infrastructure : OFFERT, jusqu'à cinq machines, avec UN JOUR d'historique.
#                      C'est ce que ce module active, et strictement rien d'autre.
#   - Log Management : PAYANT. 0,10 $ le Go ingéré, 1,70 $ le million
#                      d'événements indexés. C'est le produit qui lirait le
#                      journal de la machine, et il n'est jamais offert.
#   - APM (traces)   : PAYANT.
#   - Live Processes : PAYANT.
#
# LE PIÈGE, et c'est la seule chose à retenir de cet en-tête : un compte NEUF
# démarre par un essai de quatorze jours pendant lequel TOUT est allumé. Les
# logs arrivent, les traces arrivent, tout a l'air de marcher — puis le compte
# retombe sur le gratuit, Datadog cesse d'accepter ce qu'il n'a plus le droit de
# recevoir, et les pages correspondantes se vident. Aucun message n'est émis
# nulle part, ni côté agent ni côté interface. Une configuration réglée pendant
# l'essai meurt donc en silence le quinzième jour, ce qui est exactement le mode
# de panne contre lequel le reste de ce dépôt est écrit.
#
# D'où le parti pris : tout ce qui sort du gratuit est coupé ICI, explicitement,
# et pas laissé au défaut du module amont. Les défauts amont coupent déjà la
# plupart de ces briques, mais un défaut n'est pas une décision — il change à
# une mise à jour de nixpkgs sans que personne ne relise ce fichier. Écrites en
# dur, ces valeurs ont une seconde vertu : une définition contraire posée
# ailleurs n'écrase rien en douce, elle échoue à l'évaluation sur « conflicting
# definition values ». On ne peut donc pas quitter le gratuit par accident.
#
# CE QUE ÇA N'APPORTE PAS, et il faut l'écrire parce que c'est l'essentiel :
# cette machine mesure DÉJÀ tout ça, et mieux (cf. modules/system/server/monitoring).
# node_exporter voit plus de choses que l'agent en offre gratuite, Prometheus
# garde quatre-vingt-dix jours là où Datadog en garde UN, et Alertmanager
# prévient sur Discord — ce que le gratuit ne fait pas, les alertes relevant
# elles aussi d'une offre payante. Sur les trois axes qui comptent — ce qu'on
# voit, ce qu'on garde, ce qui prévient — l'ajout est en retrait de l'existant.
#
# CE QUE ÇA APPORTE, une seule chose, et elle est réelle : le point d'observation
# est AILLEURS. Prometheus et Grafana tournent SUR think, donc think à terre les
# emporte, et le silence qui suit ressemble à « tout va bien » — c'est la limite
# que l'en-tête du module de surveillance énonce lui-même. Datadog, lui, garde
# ce qu'il a reçu et sait dire qu'un host a cessé d'émettre. Le dead man's switch
# vers healthchecks.io couvre déjà l'alerte ; ce que Datadog ajoute par-dessus,
# c'est de pouvoir REGARDER les vingt-quatre dernières heures de courbes d'une
# machine qui ne répond plus, au moment précis où Grafana est injoignable.
#
# CE QUI SORT DE LA MAISON : les métriques système (processeur, mémoire, disque,
# réseau), le nom de la machine, et les métadonnées d'hôte que l'agent joint —
# système d'exploitation, version du noyau, temps de fonctionnement, et sa propre
# configuration résolue. Aucun contenu de journal, aucune liste de processus :
# les deux relèvent des briques payantes coupées plus bas, et le module amont ne
# démarre même pas les binaires qui les collectent. Rien de tout cela n'est
# sensible, mais ça part chez un tiers américain et ça se dit.
#
# AUCUN PORT OUVERT, et cette fois rien n'écoute non plus : l'agent n'établit que
# des connexions SORTANTES en HTTPS vers son site. DogStatsD — le seul écouteur
# que le module amont allume par défaut — est coupé, cf. l'option `dogstatsd`.
let
  cfg = config.systemSettings.datadog;
in
{
  options.systemSettings.datadog = {
    enable = lib.mkEnableOption "agent Datadog (métriques d'infrastructure, offre gratuite)";

    apiKeyKey = lib.mkOption {
      type = lib.types.str;
      default = "datadog/api_key";
      description = ''
        Clé sops de la clé d'API du compte, dans les secrets SYSTÈME : l'agent
        tourne sous son propre compte de service, il ne peut pas lire
        `/run/user/<uid>`. Contenu brut, les trente-deux caractères que Datadog
        affiche dans « Organization Settings > API Keys ».

        C'EST UNE CAPACITÉ D'ÉCRITURE, pas un identifiant de lecture : qui la
        détient peut écrire des métriques dans ton compte sous n'importe quel
        nom de machine, donc noyer les vraies mesures et faire sauter le
        plafond des cinq hosts. Elle ne permet en revanche RIEN de lire — c'est
        la clé d'APPLICATION, que ce module ne déclare pas, qui ouvre l'API en
        lecture. Ne pas confondre les deux au moment de la copier.

        À rendre depuis l'interface, pas à réutiliser d'une machine à l'autre :
        une clé par host permet d'en révoquer une sans couper les autres.
      '';
    };

    site = lib.mkOption {
      type = lib.types.str;
      default = "datadoghq.eu";
      example = "datadoghq.com";
      description = ''
        Région du compte, celle où les données sont stockées et où l'interface
        se consulte — `datadoghq.eu` correspond à app.datadoghq.eu.

        Le défaut est l'Europe, sur le seul critère qui se décide ici : des
        mesures de la maison n'ont pas de raison de traverser l'Atlantique
        quand une région européenne existe.

        CE N'EST PAS UN CHOIX LIBRE : la valeur doit correspondre à la région
        choisie à la création du compte, qui ne se change plus après coup. Une
        valeur qui ne correspond pas fait rejeter la clé d'API et l'agent tourne
        sans jamais rien publier — l'unité reste `active`, l'interface reste
        vide, et rien ne relie l'un à l'autre. `datadog-agent status` est le
        seul endroit qui le dise.

        UN NOM DE DOMAINE NU, pas une URL : l'agent construit ses points
        d'entrée en préfixant cette valeur, donc `https://app.datadoghq.eu`
        donnerait des noms qui ne résolvent nulle part. Une assertion refuse la
        forme URL, cette erreur-là étant autrement muette.
      '';
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        Nom sous lequel la machine apparaît dans l'interface.

        POSÉ EXPLICITEMENT et non laissé à la découverte de l'agent, parce que
        c'est ce nom qui compte les hosts contre le plafond de cinq. Laissé à
        lui-même, l'agent le déduit de plusieurs sources dans un ordre à lui et
        peut en changer d'un démarrage à l'autre : la même machine apparaîtrait
        alors deux fois, avec deux historiques coupés en deux, et le plafond se
        rapprocherait sans que rien n'ait bougé.

        Le défaut suit `networking.hostName`, donc le nom de la cible du flake
        (`server-think`). Il change si le profil change, ce qui est le
        comportement voulu : c'est bien une autre machine du point de vue de ce
        qu'on mesure.
      '';
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "role:serveur" ];
      description = ''
        Étiquettes `clé:valeur` attachées à toutes les métriques de ce host.

        Sans objet tant qu'il n'y a qu'une machine — filtrer un ensemble d'un
        seul élément ne sert à rien. Ça le devient dès la deuxième, les
        étiquettes étant le seul moyen d'agréger ou de comparer dans l'interface.

        Ne PAS y mettre `host:` : Datadog réserve cette clé et la remplit
        lui-même depuis `hostname` ci-dessus.
      '';
    };

    dogstatsd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Écouteur DogStatsD, par lequel une application de la machine pousserait
        ses propres métriques applicatives à l'agent.

        FAUX ici alors que le module amont l'allume, et c'est le seul réglage de
        ce fichier qui retire quelque chose : rien sur ce host n'émet de
        métrique DogStatsD. Ce qu'il laissait derrière lui était donc un socket
        UDP ouvert sur 8125 que personne n'utilise — sur la boucle locale
        seulement, donc sans exposition réseau, mais c'est de la surface qui ne
        rend aucun service.

        À rallumer le jour où une application d'ici a des métriques à publier.
        Ce ne sera pas le cas des applications de `systemSettings.apps` : elles
        tournent en conteneur, sans accès à la boucle locale du host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # `https://app.datadoghq.eu` est la valeur qu'on a sous les yeux quand on
        # cherche cette information, et elle est fausse. L'agent la reprend telle
        # quelle, fabrique des points d'entrée qui ne résolvent pas, et échoue à
        # publier sans que l'unité en souffre.
        assertion = !(lib.hasInfix "/" cfg.site) && !(lib.hasInfix ":" cfg.site);
        message = "systemSettings.datadog.site attend un nom de domaine nu (datadoghq.eu), pas une URL — l'agent préfixe cette valeur pour construire ses points d'entrée.";
      }
      {
        assertion = !(lib.any (t: lib.hasPrefix "host:" t) cfg.tags);
        message = "systemSettings.datadog.tags : la clé `host:` est réservée par Datadog, qui la remplit depuis systemSettings.datadog.hostname. Une valeur posée à la main y crée un second host.";
      }
    ];

    # `owner` et pas seulement `mode` : le module amont lit ce fichier depuis le
    # `script` de l'unité, qui tourne DÉJÀ sous le compte `datadog`
    # (`PermissionsStartOnly` ne relève les privilèges que du `preStart`). Un
    # secret laissé à root en 0400 lui serait refusé.
    #
    # Le compte existe au moment où sops déchiffre : son script d'activation est
    # ordonné après `users` et `groups`, et c'est le module amont qui déclare
    # `users.users.datadog`, statique — donc un nom qu'un `owner` peut désigner,
    # contrairement aux unités en `DynamicUser`.
    #
    # `restartUnits` : l'agent lit la clé UNE FOIS, au démarrage (`export
    # DD_API_KEY=$(head -n 1 …)`). Sans cette ligne, une rotation réécrit
    # /run/secrets sans que le démon la reprenne — il continue de publier avec
    # l'ancienne clé jusqu'au prochain redémarrage fortuit, et si celle-ci a été
    # révoquée entre-temps, il publie dans le vide.
    sops.secrets.${cfg.apiKeyKey} = {
      mode = "0400";
      owner = "datadog";
      restartUnits = [ "datadog-agent.service" ];
    };

    services.datadog-agent = {
      enable = true;

      apiKeyFile = config.sops.secrets.${cfg.apiKeyKey}.path;

      inherit (cfg) site hostname;

      # `null` et non `[ ]` quand la liste est vide : le module amont teste la
      # nullité, une liste vide lui ferait écrire `tags: ""` dans datadog.yaml.
      tags = if cfg.tags == [ ] then null else cfg.tags;

      # LES DEUX LIGNES QUI TIENNENT LE MODULE DANS LE GRATUIT. Elles valent déjà
      # `false` en amont ; les écrire les rend opposables, cf. l'en-tête. Chacune
      # démarre un binaire de plus, et chacun de ces binaires alimente un produit
      # facturé :
      #
      #   - le trace-agent alimente APM, facturé au host analysé ;
      #   - le process-agent alimente Live Processes, facturé au host, et publie
      #     au passage la liste des processus de la machine — la seule chose de
      #     ce montage qui dirait à un tiers ce qui tourne ici.
      #
      # Tant qu'ils restent faux, ces binaires ne sont pas lancés du tout : ce
      # n'est pas un filtrage côté Datadog, il n'y a rien qui parte.
      enableTraceAgent = false;
      enableLiveProcessCollection = false;

      # BOGUE DU MODULE AMONT, pas un réglage. Son défaut pour ce check écrit
      # `use_mount: "false"` — la CHAÎNE, pas le booléen — ce que l'agent 7.75
      # refuse de lire :
      #
      #   could not configure check disk: yaml: unmarshal errors
      #
      # Le check ne démarre alors pas du tout, et il n'y a AUCUNE métrique de
      # disque. La panne est muette côté interface : les autres checks tournent,
      # l'agent se déclare en bonne santé, et il manque simplement une famille de
      # mesures que personne ne remarque tant qu'il ne cherche pas un disque qui
      # se remplit — c'est-à-dire le jour où on en a besoin.
      #
      # Le défaut amont date d'une version de l'agent qui acceptait encore la
      # chaîne. À retirer quand nixpkgs l'aura corrigé : le symptôme serait alors
      # une simple redondance, pas une panne.
      diskCheck = {
        init_config = { };
        instances = [ { use_mount = false; } ];
      };

      # Fusionné EN DERNIER par le module amont, donc ces clés l'emportent sur
      # les siennes — c'est le seul moyen de revenir sur `use_dogstatsd`, qu'il
      # écrit en dur.
      extraConfig = {
        # LA LIGNE QUI DIT LE CHOIX FAIT DANS CE MODULE. L'agent sait collecter
        # le journal de la machine ; le compte gratuit n'a pas le droit de le
        # recevoir. La laisser à `true` produirait exactement la panne décrite en
        # tête de fichier : quatorze jours de logs pendant l'essai, puis plus
        # rien, sans message.
        #
        # POUR LES ALLUMER UN JOUR — il faut un plan payant, compter dans ce cas
        # de l'ordre d'un dollar par mois au volume actuel de think (~15 700
        # lignes et ~4 Mo de journal par jour, dont un tiers vient de la seule
        # sonde blackbox `http_authelia`, qui journalise chaque redirection
        # attendue) :
        #
        #   logs_enabled = true;
        #
        # puis une source, par exemple le journal complet :
        #
        #   services.datadog-agent.checks.journald.logs = [
        #     { type = "journald"; }
        #   ];
        #
        # et l'agent doit entrer dans le groupe qui ouvre le journal, ce que le
        # module amont ne fait pas :
        #
        #   users.users.datadog.extraGroups = [ "systemd-journal" ];
        #
        # Sans ce dernier point l'agent démarre, se déclare en bonne santé, et ne
        # lit rien.
        logs_enabled = false;

        # Le défaut de l'AGENT est `true`, contrairement aux deux options
        # ci-dessus dont le défaut nixpkgs suffisait. Le module amont n'écrit
        # cette clé que lorsque `enableTraceAgent` est vrai, donc sans cette
        # ligne l'agent se déclare prêt à recevoir des traces et ouvre le port
        # correspondant. Aucune n'arriverait — le binaire qui les recevrait n'est
        # pas lancé — mais autant que la configuration dise ce qui est vrai.
        apm_config.enabled = false;

        use_dogstatsd = cfg.dogstatsd;

        # CANAL DE CONFIGURATION À DISTANCE, par lequel Datadog pousse des
        # réglages à l'agent depuis leur interface. Coupé pour deux raisons, et
        # la première suffirait :
        #
        #   - LA CONFIGURATION DE CETTE MACHINE VIENT DU DÉPÔT. Un mécanisme qui
        #     permet à un tiers de la modifier en dehors de tout rebuild défait
        #     ce que tout ce dépôt construit : ce qui tourne ne serait plus ce
        #     que le dépôt décrit, et l'écart ne se verrait dans aucun diff.
        #   - il échoue de toute façon ici. L'agent veut écrire sa base d'état
        #     dans /opt/datadog-agent, chemin qui n'existe pas sur NixOS et que
        #     son compte ne peut pas créer :
        #
        #       failed to create rc db dir: (/opt/datadog-agent/run/remote-config.db):
        #       mkdir /opt/datadog-agent: permission denied
        #
        #     D'où une ERREUR à chaque démarrage, et un « Startup Failure Reason »
        #     permanent dans `agent status`. Une erreur qu'on a décidé d'ignorer
        #     est une erreur qu'on finit par ne plus lire — et c'est le journal
        #     de cette machine qu'on aveugle.
        #
        # Rien n'est perdu : ce canal ne sert qu'aux produits payants (APM,
        # sécurité, tests synthétiques), tous coupés.
        remote_configuration.enabled = false;
      };
    };

    systemSettings.notify.discord.units = [ "datadog-agent" ];

    # ATTENDRE LE RÉSOLVEUR LOCAL, pour la même raison que le tunnel (cf.
    # modules/system/server/cloudflared) mais avec un enjeu moindre : la
    # première chose que fait l'agent est de résoudre son site, et dnsmasq
    # n'est pas forcément debout au moment où `network-online.target` est
    # atteinte.
    #
    # L'agent RÉESSAIE, lui, donc ce qu'on évite n'est pas une panne mais une
    # rafale d'erreurs de résolution dans le journal à chaque démarrage de la
    # machine — c'est-à-dire du bruit dans le seul endroit où l'on va
    # regarder quand quelque chose ne va vraiment pas.
    systemd.services.datadog-agent = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };
    systemSettings.dns.dependentUnits = [ "datadog-agent" ];
  };
}
