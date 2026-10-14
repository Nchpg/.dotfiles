{
  config,
  lib,
  ...
}:

# Conteneurs des applications : leurs options, leur lancement par podman, le
# réseau dédié de chaque application et l'ordre de démarrage. Cf. default.nix
# pour le modèle d'ensemble.
let
  cfg = config.systemSettings.apps;

  podmanBin = lib.getExe' config.virtualisation.podman.package "podman";

  # Nom d'unité du conteneur, construit comme le fait le module amont à partir
  # du backend que CE module impose juste en dessous. La dépendance est assumée
  # parce qu'elle est interne : c'est le même module qui fixe `backend` et qui
  # lit ce nom.
  unitOf = key: "podman-${key}";

  containerKey = appName: containerName: "${appName}-${containerName}";

  # Liste PLATE de tout ce qui doit tourner. Les conteneurs y sont tous traités
  # pareil, ce qui est la seule façon de garantir qu'aucun n'échappe au
  # durcissement — le service qui exécute du code métier ne doit pas être MOINS
  # tenu que celui qui sert des fichiers statiques.
  allContainers = lib.concatLists (
    lib.mapAttrsToList (
      appName: app:
      lib.mapAttrsToList (containerName: container: {
        key = containerKey appName containerName;
        inherit
          appName
          app
          containerName
          container
          ;
        isEntrypoint = containerName == app.entrypointName;
      }) app.containers
    ) cfg
  );

  # `ghcr.io/moi/app@sha256:…` -> `ghcr.io`. Un nom sans hôte vient de Docker
  # Hub, qui n'a pas besoin d'identifiants ici : aucune image n'en vient.
  registryOf = image: lib.head (lib.splitString "/" image);

  containerOptions = {
    image = lib.mkOption {
      type = lib.types.str;
      example = "ghcr.io/moi/monsite@sha256:abc123…";
      description = ''
        Image du conteneur.

        UN DIGEST plutôt qu'un tag, comme le reste du dépôt épingle ce qu'il
        déploie. La version qui tourne est alors écrite ici, se relit en diff, et
        revient en arrière avec la génération — un tag mutable ferait dépendre le
        contenu servi de ce qui se trouve sur le registre au moment du tirage,
        sans que rien ne le consigne.

        Ça suppose une étape manuelle à chaque mise à jour : publier l'image,
        relever le digest, le remplacer ici, rebuild. C'est le prix pour que rien
        ne s'exécute sur cette machine sans être passé par un diff.
      '';
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8000;
      description = ''
        Port sur lequel l'image écoute, à l'intérieur du conteneur.

        Il n'est PUBLIÉ que pour le point d'entrée, seul conteneur que nginx doit
        atteindre — une assertion l'exige donc pour lui. Les autres restent
        joignables par leurs pairs sur le réseau de l'application, sur le port
        qu'ils veulent, et n'ouvrent rien sur le host.

        LE DÉCLARER QUAND MÊME quand il est sous 1024, y compris sur un conteneur
        qui ne publie rien : c'est de cette valeur que le module déduit s'il faut
        rendre `CAP_NET_BIND_SERVICE`.

        `null` PAR DÉFAUT, et c'est une décision de sécurité. La version
        précédente valait 80, donc tout conteneur qui ne déclarait pas son port
        recevait cette capacité sans en avoir besoin — un défaut qui accorde un
        privilège est un défaut qui se trompe de sens.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Variables d'environnement. Rien de secret ici : leur valeur finit en
        clair dans le store, lisible par tous les utilisateurs de la machine et
        publiée avec le dépôt. Pour un secret, passer par `environmentFiles`.
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression ''[ config.sops.secrets."monapp/env".path ]'';
      description = "Fichiers d'environnement, pour les secrets (sops).";
    };

    login = lib.mkOption {
      default = null;
      description = ''
        Identifiants du registre, pour une image PRIVÉE. `null` : tirage
        anonyme, ce qui suffit aux images publiques.

        Le registre est déduit de l'image, pour qu'il ne puisse pas désigner un
        autre hôte que celui d'où elle vient. Le jeton est un secret sops, lu
        par `podman login` depuis /run/secrets et jamais écrit dans le store.

        Un jeton en LECTURE seule (`read:packages` pour ghcr.io) : c'est tout ce
        que think fait d'un registre.
      '';
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            username = lib.mkOption {
              type = lib.types.str;
              example = "moi";
              description = "Compte du registre.";
            };

            passwordKey = lib.mkOption {
              type = lib.types.str;
              example = "ghcr/token";
              description = ''
                Clé sops du jeton. Le module la DÉCLARE lui-même et lit le chemin
                du secret déchiffré : rien à écrire ailleurs, et deux applications
                qui partagent un jeton partagent la clé sans conflit — les
                déclarations fusionnent.
              '';
            };
          };
        }
      );
    };

    cmd = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--workers"
        "4"
      ];
      description = ''
        Remplace la commande de l'image — l'équivalent du `command:` de compose.

        Liste vide : celle de l'image est conservée. Indispensable dès qu'une
        même image sert plusieurs rôles, ce qui est le cas courant dans un
        compose un peu fourni — un conteneur qui sert l'API et un autre qui
        consomme une file, à partir du même binaire.
      '';
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "1000:1000";
      description = ''
        Utilisateur sous lequel le conteneur s'exécute, au format `uid[:gid]`.

        `null` laisse celui de l'image, qui est root neuf fois sur dix. Le poser
        est le durcissement le plus efficace qui reste une fois les capacités
        retirées : un processus non privilégié n'a rien à regagner, même si une
        faille lui donne l'exécution de code.

        À vérifier avant : l'image doit pouvoir écrire ce dont elle a besoin sous
        cet identifiant. Beaucoup n'en sont pas capables sans un volume préparé,
        et c'est pour ça que ce n'est pas le défaut.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2g";
      description = ''
        Plafond de mémoire du conteneur, au format de podman (`512m`, `2g`).

        POURQUOI ÇA COMPTE sur cette machine : le tueur de mémoire du noyau ne
        tue pas le coupable, il tue ce qui l'arrange. Un conteneur qui dérape
        peut donc faire tomber PostgreSQL ou Nextcloud plutôt que lui-même. Avec
        un plafond, il meurt seul et redémarre, et la panne reste chez lui.

        `null` par défaut parce qu'une valeur choisie au hasard est pire que
        rien : trop basse, le conteneur est tué dès le chargement d'un modèle ou
        d'un cache. À poser d'après une MESURE — `systemctl show <unité> -p
        MemoryCurrent` au repos puis en charge — avec environ un tiers de marge.
      '';
    };

    pidsLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = ''
        Plafond de processus, contre l'épuisement par fork — accidentel comme
        délibéré.

        Deux cent cinquante-six est très large pour un serveur web. Ça peut être
        étroit pour un service qui engendre un processus par connexion :
        PostgreSQL en est l'exemple type. Ce qui compte est qu'une borne existe,
        la valeur par défaut du moteur étant celle du host tout entier.
      '';
    };

    capabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "CHOWN"
        "SETUID"
        "SETGID"
      ];
      description = ''
        Capacités RENDUES à ce conteneur, par-dessus le retrait de toutes.

        Le module retire l'intégralité des capacités par défaut, ce qui convient
        à un serveur qui se contente d'écouter et de lire des fichiers. Beaucoup
        d'images officielles font autre chose : elles démarrent en root, ajustent
        les droits de leurs répertoires de travail, puis abandonnent leurs
        privilèges pour lancer leurs processus de travail. L'image nginx officielle
        réclame ainsi `CHOWN`, `SETUID` et `SETGID`, et échoue sinon sur
        `chown(…) failed (1: Operation not permitted)`.

        `NET_BIND_SERVICE` n'a PAS à figurer ici : elle est déduite du `port`,
        parce qu'elle relève d'une règle du noyau et non d'un choix de l'image.

        À REMPLIR AU COMPTE-GOUTTES, en partant de zéro et en ajoutant ce que le
        journal réclame. Une image qui en exige beaucoup dit quelque chose sur
        elle-même : le plus souvent qu'il existe une variante `-unprivileged`
        qu'il vaudrait mieux employer.
      '';
    };

    dependsOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "backend" ];
      description = ''
        Conteneurs de la MÊME application à démarrer avant celui-ci —
        l'équivalent du `depends_on` de compose.

        CE N'EST PAS DU CONFORT. Un serveur qui résout ses pairs au démarrage
        plutôt qu'à chaque requête — c'est le cas de nginx avec un `proxy_pass`
        sans variable — meurt sur `host not found in upstream` si le pair n'est
        pas encore enregistré dans le DNS du réseau. Il redémarre alors en
        boucle, et le seul symptôme visible est une passerelle défaillante.

        Ne crée aucune attente sur la DISPONIBILITÉ du pair, seulement sur son
        démarrage : podman enregistre le nom dès la création du conteneur, ce qui
        suffit à la résolution, mais une application qui exige que son pair
        RÉPONDE doit savoir réessayer.
      '';
    };

    healthcheck = {
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "curl -fsS http://localhost:8000/health";
        description = ''
          Commande exécutée DANS le conteneur pour dire s'il est prêt. Passée au
          shell, comme le `CMD-SHELL` de compose. `null` : aucune sonde.

          CE QUE ÇA CHANGE, et c'est le seul moyen d'exprimer la notion de
          « prêt » : tant qu'aucune sonde n'est déclarée, systemd considère
          l'unité démarrée dès que le conteneur est CRÉÉ. Un `dependsOn` n'ordonne
          alors que des démarrages, et un pair qui attend une base de données
          l'attaque pendant qu'elle initialise encore son répertoire de données.

          Avec une sonde, podman ne signale l'unité prête qu'une fois celle-ci au
          vert, et tout ce qui en dépend patiente vraiment. C'est l'équivalent
          exact du `condition: service_healthy` de compose.

          La commande doit exister DANS l'image : beaucoup d'images minimales
          n'ont ni `curl` ni `wget`. Une base PostgreSQL utilisera `pg_isready`,
          qu'elle fournit ; pour un serveur HTTP sans client HTTP embarqué, le
          plus sûr est souvent une sonde sur le port avec les outils du langage.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Intervalle entre deux exécutions de la sonde.";
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "5s";
        description = "Délai au-delà duquel une exécution de la sonde compte comme un échec.";
      };

      retries = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Échecs consécutifs avant que le conteneur soit déclaré malade.";
      };

      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = ''
          Durée de grâce au démarrage, pendant laquelle un échec de la sonde ne
          compte PAS dans les tentatives.

          Indispensable pour tout ce qui met du temps à s'initialiser — une base
          de données qui prépare son répertoire, un service qui charge un modèle.
          Sans elle, la sonde épuise ses tentatives avant que le service ait eu
          une chance de répondre, et le conteneur est déclaré malade alors qu'il
          allait très bien.
        '';
      };
    };

    volumes = lib.mkOption {
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            source = "donnees";
            target = "/var/lib/postgresql/data";
            readOnly = false;
          }
        ]
      '';
      description = ''
        Montages du conteneur.

        STRUCTURÉ plutôt qu'une chaîne `source:destination:options`. La forme
        brute laissait écrire n'importe quoi sans qu'aucune relecture ne
        l'attrape — `/:/host` est une chaîne parfaitement valide, et elle donne
        au conteneur le système de fichiers entier de la machine.

        Un `source` sans barre oblique initiale désigne un VOLUME NOMMÉ, que
        podman crée au besoin et range sous
        `/var/lib/containers/storage/volumes/<nom>/_data`. C'est la forme à
        préférer : elle ne donne accès à rien du host. À noter pour le jour où
        une sauvegarde sera mise en place — rien ici ne s'en occupe.
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              example = "donnees";
              description = "Nom d'un volume géré par podman, ou chemin absolu sur le host.";
            };

            target = lib.mkOption {
              type = lib.types.str;
              example = "/var/lib/postgresql/data";
              description = "Chemin de montage à l'intérieur du conteneur, absolu.";
            };

            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Monte en lecture seule.

                VRAI PAR DÉFAUT, à l'inverse du moteur de conteneurs. Il faut donc
                écrire explicitement qu'un montage est modifiable, ce qui rend la
                poignée de montages dangereux visible en relecture au lieu de les
                noyer parmi ceux qui ne le sont pas.
              '';
            };
          };
        }
      );
    };
  };
in
{
  options.systemSettings.apps = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.containers = lib.mkOption {
          description = ''
            Conteneurs de l'application, un par service — la traduction
            directe des `services:` d'un fichier compose.

            DÈS QU'IL Y EN A PLUSIEURS, ils rejoignent un réseau dédié à
            cette application et s'y résolvent PAR LE NOM DÉCLARÉ ICI. Un
            `proxy_pass http://backend:8000` ou un
            `DATABASE_URL=postgres://db/…` écrits pour compose fonctionnent
            sans être touchés.

            Le réseau est propre à l'application : deux applications ne se
            voient pas, même si elles nomment un service pareil.
          '';
          type = lib.types.attrsOf (lib.types.submodule { options = containerOptions; });
        };
      }
    );
  };

  config = lib.mkIf (cfg != { }) {
    # Jetons des registres privés, déclarés ici puisque c'est ce module qui les
    # lit (cf. `login.passwordKey`). Lus par root, au `podman login` qui
    # précède le tirage.
    sops.secrets = lib.listToAttrs (
      map (c: lib.nameValuePair c.container.login.passwordKey { }) (
        lib.filter (c: c.container.login != null) allContainers
      )
    );

    # PODMAN, ÉCRIT EXPLICITEMENT plutôt que laissé au défaut.
    #
    # Le défaut amont de `backend` dépend de `system.stateVersion` : podman à
    # partir de 22.05, docker en dessous. Une valeur qui bascule selon un numéro
    # posé une fois à l'installation et jamais relu n'est pas un choix, c'est un
    # accident qui a bien tourné. On l'inscrit — d'autant que tout ce module en
    # dépend, du nom des unités aux réseaux nommés.
    #
    # Podman n'a PAS de démon : chaque conteneur est une unité systemd qui
    # exécute le processus directement. Il n'y a donc aucun socket à protéger,
    # contrairement à Docker dont l'accès au socket équivaut à être root.
    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers = lib.listToAttrs (
      map (
        c:
        lib.nameValuePair c.key {
          inherit (c.container)
            image
            environmentFiles
            environment
            ;

          volumes = map (
            v: "${v.source}:${v.target}${lib.optionalString v.readOnly ":ro"}"
          ) c.container.volumes;

          # `healthy` : podman ne signale l'unité PRÊTE qu'une fois la sonde au
          # vert, et non dès la création du conteneur. C'est ce seul réglage qui
          # donne à `dependsOn` la sémantique du `condition: service_healthy` de
          # compose — sans lui, un pair attend une existence, pas une
          # disponibilité.
          podman.sdnotify = if c.container.healthcheck.command != null then "healthy" else "conmon";

          # SEUL LE POINT D'ENTRÉE EST PUBLIÉ, et seulement sur la boucle locale :
          # nginx est le seul à devoir l'atteindre, et c'est lui qui apporte le
          # TLS. Les autres conteneurs n'ouvrent RIEN sur le host — ni sur le
          # LAN, ni en local — et restent joignables uniquement par leurs pairs.
          #
          # Un bind plus large exposerait le service en clair sur le LAN, en
          # contournant au passage le pare-feu NixOS, le moteur de conteneurs
          # insérant ses propres règles.
          ports = lib.optional c.isEntrypoint "127.0.0.1:${toString c.app.hostPortEffective}:${toString c.container.port}";

          networks = lib.singleton c.app.network;

          dependsOn = map (n: containerKey c.appName n) c.container.dependsOn;

          inherit (c.container) cmd user;

          login = lib.mkIf (c.container.login != null) {
            registry = registryOf c.container.image;
            inherit (c.container.login) username;
            passwordFile = config.sops.secrets.${c.container.login.passwordKey}.path;
          };

          extraOptions = [
            # AUCUNE capacité. Un processus qui écoute au-dessus de 1024 et sert
            # des fichiers n'en utilise pas une seule. Sans ça, le moteur en
            # accorde une dizaine par défaut, dont CAP_CHOWN, CAP_SETUID et
            # CAP_MKNOD — de quoi transformer une exécution de code arbitraire
            # dans le conteneur en quelque chose de nettement plus intéressant.
            "--cap-drop=ALL"

            # Interdit à un binaire setuid de regagner des privilèges à
            # l'intérieur du conteneur. C'est la brique qui rend le `cap-drop`
            # ci-dessus difficile à contourner plutôt que simplement
            # décourageant.
            "--security-opt=no-new-privileges"

            "--pids-limit=${toString c.container.pidsLimit}"
          ]
          # Plafond de mémoire, quand il a été mesuré. Sans lui, un conteneur qui
          # dérape entraîne le tueur de mémoire du noyau, lequel ne s'en prend
          # pas forcément au coupable.
          ++ lib.optional (c.container.memory != null) "--memory=${c.container.memory}"
          # LA SEULE CAPACITÉ RENDUE, et seulement à qui en a besoin. Aucun
          # processus, pas même root, ne peut se lier à un port sous 1024 sans
          # `CAP_NET_BIND_SERVICE` — or `--cap-drop=ALL` la retire aussi. Une
          # image officielle nginx, qui écoute sur 80, échoue alors sur
          # `bind() to 0.0.0.0:80 failed (13: Permission denied)`.
          #
          # Déduite du port déclaré plutôt que laissée en réglage : personne ne
          # devrait avoir à connaître cette règle du noyau pour publier un site.
          # C'est aussi pourquoi `port` doit dire la vérité sur TOUS les
          # conteneurs, même ceux qui ne publient rien.
          ++ lib.optional (c.container.port != null && c.container.port < 1024) "--cap-add=NET_BIND_SERVICE"

          # Ce que l'image réclame en propre, déclaré conteneur par conteneur.
          # Toujours APRÈS le retrait global : c'est l'ordre qui fait qu'on rend
          # une liste choisie plutôt qu'on en retire une.
          ++ map (cap: "--cap-add=${cap}") c.container.capabilities

          # La sonde de disponibilité, quand elle est déclarée. `start-period`
          # n'est pas un confort : pendant cette fenêtre un échec ne compte pas
          # dans les tentatives, ce qui laisse à un service lent le temps de
          # s'initialiser sans être déclaré malade avant d'avoir répondu une
          # seule fois.
          ++ lib.optionals (c.container.healthcheck.command != null) [
            "--health-cmd=${c.container.healthcheck.command}"
            "--health-interval=${c.container.healthcheck.interval}"
            "--health-timeout=${c.container.healthcheck.timeout}"
            "--health-retries=${toString c.container.healthcheck.retries}"
            "--health-start-period=${c.container.healthcheck.startPeriod}"
          ]
          # LE NOM COURT, celui que les pairs emploient. L'unité s'appelle
          # `<app>-<service>` pour qu'elle soit unique sur la machine, mais un
          # fichier de configuration écrit pour compose dit `backend`, pas
          # `rlkart-backend`. L'alias réconcilie les deux sans rien avoir à
          # réécrire dans l'image.
          ++ lib.singleton "--network-alias=${c.containerName}";
        }
      ) allContainers
    );

    # LE RÉSEAU DE CHAQUE APPLICATION, créé avant ses conteneurs.
    #
    # Le module amont sait ATTACHER un conteneur à un réseau, il ne sait pas le
    # créer : `podman run --network=X` échoue si X n'existe pas. D'où cette unité,
    # et le `requires` posé plus bas sur chaque conteneur.
    #
    # ELLE COMPARE LA CONFIGURATION, pas seulement l'existence. `podman network
    # exists` ne dit qu'une chose : un réseau de ce NOM est là. Il ne dit rien de
    # ses options — et un réseau créé par une version antérieure de ce module
    # garde son ancien pont, pendant que les règles de pare-feu visent le
    # nouveau. Plus rien ne passe, et aucun message ne relie les deux.
    #
    # Constaté : après le passage aux ponts nommés, `podman network exists`
    # répondait vrai, la création était sautée, le pont s'appelait toujours
    # `podman1` et les règles ne correspondaient à rien. Il a fallu supprimer le
    # réseau à la main. Ce genre de bascule doit être automatique, sinon le
    # prochain changement d'option réseau coûtera la même demi-heure.
    systemd.services = lib.mkMerge (
      (lib.mapAttrsToList (appName: app: {
        ${app.networkUnit} = {
          description = "Réseau des conteneurs de ${appName}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          # `script` et non `serviceConfig.ExecStart` : le `||` est une
          # construction du SHELL, que systemd n'interprète pas. En ExecStart,
          # podman recevrait « || » comme argument.
          #
          # ARGUMENTS ÉCHAPPÉS, parce que ceci est un shell lancé par root :
          # les noms viennent de la configuration et non d'un inconnu, mais une
          # interpolation nue dans une commande privilégiée est une mauvaise
          # habitude qui finit par rencontrer une valeur inattendue. Une
          # assertion restreint déjà les noms ; l'échappement est la seconde
          # barrière.
          #
          # `isolate=true` : netavark bloque alors le trafic entre réseaux
          # portant cette option. Ce n'est PAS son défaut — la page de manuel
          # est explicite, l'isolation ne vaut qu'entre réseaux qui l'ont
          # demandée. Deux applications ne peuvent donc pas se parler, et ça ne
          # dépend pas seulement des règles de pare-feu (cf. firewall.nix).
          script =
            let
              net = lib.escapeShellArg app.network;
              bridge = lib.escapeShellArg app.bridge;
              opts = lib.escapeShellArgs [
                "--opt"
                "com.docker.network.bridge.name=${app.bridge}"
                "--opt"
                "isolate=true"
              ];
            in
            ''
              create() {
                ${podmanBin} network create ${opts} ${net}
              }

              if ! ${podmanBin} network exists ${net}; then
                create
                exit 0
              fi

              # Le pont RÉELLEMENT en place, comparé à celui qu'on attend. Un
              # écart signifie que le réseau vient d'une version antérieure de
              # ce module et que les règles de pare-feu ne le désignent plus.
              actual=$(${podmanBin} network inspect ${net} --format '{{.NetworkInterface}}' 2> /dev/null || true)

              if [ "$actual" != ${bridge} ]; then
                echo "réseau ${app.network} : pont « $actual » au lieu de « ${app.bridge} », recréation" >&2
                # `-f` : les conteneurs attachés sont détachés d'office. Ils
                # sont `partOf` cette unité (cf. plus bas), donc systemd les a
                # déjà arrêtés avant d'arriver ici, et les redémarrera après.
                ${podmanBin} network rm -f ${net}
                create
              fi
            '';
        };
      }) cfg)

      # Chaque conteneur attend son réseau. `requires` et pas seulement `after` :
      # un conteneur démarré sans son réseau ne dégrade pas, il échoue.
      #
      # `partOf` en plus, et c'est ce qui rend la recréation du réseau sûre :
      # arrêter ou redémarrer l'unité du réseau arrête d'abord les conteneurs qui
      # en font partie, et les relance ensuite. Sans lui, une recréation
      # arracherait le pont sous des conteneurs qui continueraient de tourner en
      # croyant être connectés.
      ++ (map (c: {
        ${unitOf c.key} = {
          after = [ "${c.app.networkUnit}.service" ];
          requires = [ "${c.app.networkUnit}.service" ];
          partOf = [ "${c.app.networkUnit}.service" ];
        };
      }) allContainers)

      # DÉLAI ENTRE DEUX TENTATIVES, porté à dix secondes.
      #
      # Le défaut de systemd est de cent millisecondes : cinq essais tiennent
      # dans une demi-seconde, la limite de démarrage est atteinte, et l'unité
      # abandonne DÉFINITIVEMENT — il faut alors un `systemctl reset-failed` à la
      # main. C'est arrivé quatre fois aujourd'hui, sur des pannes qui se
      # seraient résolues seules en laissant à un pair le temps d'apparaître.
      #
      # On ne DÉSACTIVE pas la limite pour autant, alors que ce serait tentant :
      # une unité qui réessaie indéfiniment ne passe jamais en `failed`, donc
      # `UniteSystemdEnEchec` ne se déclenche jamais et la panne devient
      # silencieuse. Mieux vaut cinquante secondes de patience puis un échec
      # visible, qu'une boucle éternelle que personne ne remarque.
      ++ (map (c: { ${unitOf c.key}.serviceConfig.RestartSec = "10s"; }) allContainers)

      # DÉLAI DE DÉMARRAGE ALLONGÉ pour les conteneurs à sonde, et il le faut :
      # avec `sdnotify=healthy`, systemd ne considère l'unité démarrée qu'une
      # fois la sonde au vert. Le défaut de quatre-vingt-dix secondes suffit à un
      # serveur web, pas à une base de données qui prépare son répertoire de
      # données au premier lancement.
      #
      # Cinq minutes, et pas l'infini : une unité qui n'aboutit jamais doit finir
      # par échouer, sinon elle reste éternellement « en cours de démarrage » —
      # un état que `UniteSystemdEnEchec` ne voit pas, donc une panne silencieuse.
      ++ (map (
        c:
        lib.optionalAttrs (c.container.healthcheck.command != null) {
          ${unitOf c.key}.serviceConfig.TimeoutStartSec = "5min";
        }
      ) allContainers)
    );
  };
}
