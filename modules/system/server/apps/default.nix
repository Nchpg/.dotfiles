{
  config,
  lib,
  myLib,
  ...
}:

# Applications web servies depuis des images de conteneurs. Chaque application
# déclarée ici pose d'un coup ses conteneurs, son vhost nginx avec certificat et
# sa route dans le tunnel — les trois blocs étant toujours les mêmes, seul ce qui
# change reste à écrire.
#
# UNE APPLICATION, PLUSIEURS CONTENEURS. Le modèle est celui de compose et le
# reproduit fidèlement : les conteneurs d'une même application partagent un
# réseau dédié et s'y résolvent PAR LEUR NOM. Un `proxy_pass http://backend:8000`
# écrit pour compose fonctionne ici sans être touché.
#
# Ce qu'il fait de MIEUX que compose, et c'est la raison de ne pas se contenter
# de lancer le fichier d'origine : un seul conteneur est publié sur le host, sur
# la boucle locale, et c'est celui que nginx sert. Les autres n'exposent AUCUN
# port — ni sur le LAN, ni sur la boucle locale — et ne sont joignables que
# depuis le réseau de leur application. Un `ports: 8000:8000` de compose, lui,
# écoute sur toutes les interfaces de la machine et laisse n'importe qui du LAN
# court-circuiter nginx.
#
# Aucun port n'est ouvert sur la box : les applications publiques passent par le
# MÊME tunnel que le reste, qui route autant de noms qu'on veut.
let
  cfg = config.systemSettings.apps;

  names = lib.attrNames cfg;

  podmanBin = lib.getExe' config.virtualisation.podman.package "podman";

  # Un tiret est légal dans un nom d'attribut Nix, pas dans un identifiant nginx.
  # Le point ne figure PLUS dans cette liste : une assertion interdit désormais
  # tout ce qui n'est ni lettre, ni chiffre, ni tiret, ni souligné, donc la
  # branche qui le traitait était morte.
  sanitize = lib.replaceStrings [ "-" ] [ "_" ];

  networkOf = appName: "app-${appName}";
  networkUnitOf = appName: "podman-network-${appName}";

  # NOM DU PONT IMPOSÉ, au lieu du `podmanN` que netavark attribue dans l'ordre
  # de création. C'est ce qui permet d'écrire des règles de pare-feu par
  # APPLICATION plutôt qu'un joker `podman*` qui les mettrait toutes dans le même
  # sac — cf. les règles plus bas, où toute la sécurité de l'isolation repose sur
  # ce nom.
  #
  # Quinze caractères maximum, limite du noyau pour un nom d'interface (IFNAMSIZ).
  # Une assertion la vérifie plutôt que de laisser podman échouer au démarrage.
  bridgeOf = appName: "br-${appName}";

  # Le conteneur que nginx sert. Quand une application n'en a qu'un, le désigner
  # serait une cérémonie sans objet : on le déduit.
  entrypointOf =
    app: if app.entrypoint != null then app.entrypoint else lib.head (lib.attrNames app.containers);

  # UN RÉSEAU PAR APPLICATION, même quand elle n'a qu'un conteneur.
  #
  # La version précédente ne le posait qu'à partir de deux, au motif qu'en
  # dessous « il n'y a personne à résoudre ». Le raisonnement oubliait ce qui
  # arrive à un conteneur sans `--network` : il rejoint le réseau PAR DÉFAUT de
  # podman, avec tous les autres qui sont dans le même cas. Deux applications
  # d'un seul conteneur se retrouvaient donc sur le même pont, libres de se
  # parler — l'inverse exact de ce que ce module annonce.
  #
  # Visible dans un `podman ps` : la colonne réseau du portfolio affichait
  # `podman`, le réseau partagé, pendant que ceux de rlkart affichaient le leur.
  #
  # Le coût d'un pont pour un conteneur seul est négligeable ; celui d'une
  # exception dans un raisonnement de cloisonnement ne l'est pas. Toutes les
  # applications sont désormais traitées pareil, ce qui supprime au passage la
  # distinction de cas dans six blocs.

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
        isEntrypoint = containerName == entrypointOf app;
      }) app.containers
    ) cfg
  );

  # Port de bouclage attribué automatiquement, pour n'avoir ni liste à tenir ni
  # collision à arbitrer. Seuls les points d'entrée en réclament un : eux seuls
  # sont publiés. Il peut se DÉCALER quand une application s'insère avant une
  # autre dans l'ordre alphabétique — sans conséquence, conteneurs et vhosts
  # étant régénérés ensemble. Détail d'implémentation, jamais une adresse à
  # communiquer.
  basePort = 8080;
  portOf = lib.listToAttrs (lib.imap0 (i: n: lib.nameValuePair n (basePort + i)) names);

  limitedApps = lib.filter (n: cfg.${n}.rateLimit.enable) names;



  zoneOf = appName: "app_${sanitize appName}";

  # Locations du vhost. Tout part au point d'entrée : l'aiguillage interne reste
  # l'affaire de l'application, exactement comme sous compose. Les chemins
  # limités sont des locations SUPPLÉMENTAIRES vers la même destination, dont le
  # seul apport est le compteur.
  locationsOf =
    appName: app:
    let
      timeout = lib.optionalString (app.proxyTimeout != null) ''
        proxy_read_timeout ${app.proxyTimeout};
        proxy_send_timeout ${app.proxyTimeout};
      '';

      target = {
        proxyPass = "http://127.0.0.1:${toString portOf.${appName}}";
        proxyWebsockets = true;
      }
      // lib.optionalAttrs (timeout != "") { extraConfig = timeout; };

      limit = timeout + ''
        limit_req zone=${zoneOf appName} burst=${toString app.rateLimit.burst} nodelay;
      '';

      limitedPaths = lib.optionals app.rateLimit.enable app.rateLimit.paths;
    in
    {
      # Liste de chemins VIDE avec la limitation active : c'est toute
      # l'application qui est comptée, y compris ses fichiers statiques.
      "/" =
        target
        // lib.optionalAttrs (app.rateLimit.enable && app.rateLimit.paths == [ ]) {
          extraConfig = limit;
        };
    }
    // lib.listToAttrs (
      map (path: lib.nameValuePair path (target // { extraConfig = limit; })) limitedPaths
    );

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
    default = { };
    description = "Applications web servies depuis des images de conteneurs.";
    example = lib.literalExpression ''
      {
        monapp = {
          domain = "monapp.exemple.fr";
          entrypoint = "frontend";
          containers = {
            frontend = { image = "ghcr.io/moi/front@sha256:…"; port = 80; };
            backend = { image = "ghcr.io/moi/api@sha256:…"; };
          };
          rateLimit.paths = [ "/api" ];
        };
      }
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            domain = lib.mkOption {
              type = lib.types.str;
              example = "monapp.exemple.fr";
              description = ''
                Nom servi. Sous `.lan.` pour une application qui ne doit pas
                sortir de la maison, à la racine du domaine sinon — cf. la
                convention de nommage du profil.
              '';
            };

            public = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Publie l'application sur internet par le tunnel. `false` la laisse
                joignable seulement depuis le LAN et le VPN, par son nom en
                `.lan.`, sans qu'aucune route ne l'expose.
              '';
            };

            containers = lib.mkOption {
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

            entrypoint = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "frontend";
              description = ''
                Conteneur que nginx sert, et le SEUL qui soit publié — sur la
                boucle locale uniquement.

                `null` quand l'application n'a qu'un conteneur : le désigner
                serait une cérémonie sans objet, il est déduit. Une assertion le
                réclame dès qu'il y en a plusieurs.

                Tout ce qui arrive sur le domaine lui est transmis, y compris les
                chemins d'API : l'aiguillage interne reste l'affaire de
                l'application, comme sous compose. Ce module ne cherche pas à
                connaître sa structure.
              '';
            };

            proxyTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "180s";
              description = ''
                Délai au-delà duquel nginx abandonne une requête en attente de
                l'application. `null` garde le défaut de nginx, soit soixante
                secondes.

                À poser pour une application dont certaines requêtes CALCULENT —
                une simulation, un rendu, une inférence. Le symptôme sans ça est
                un 504 au bout d'une minute exactement, alors que l'application
                travaille encore et finirait par répondre.

                PLAFOND À CONNAÎTRE : Cloudflare coupe à cent secondes sur le
                plan gratuit, et ce n'est pas réglable. Au-delà, aucune valeur
                ici ne sauvera quoi que ce soit pour un visiteur venu par le
                tunnel — il faut rendre le traitement asynchrone côté
                application.
              '';
            };

            rateLimit = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Limite le débit de requêtes, PAR ADRESSE CLIENTE.

                  À activer dès qu'un chemin DÉCLENCHE DU CALCUL — une API qui
                  simule, qui rend une image, qui interroge un modèle. Exposé sans
                  limite, un chemin de ce genre est un robinet à processeur ouvert
                  sur internet : n'importe qui peut boucler dessus et saturer la
                  machine, ce qui emporterait tous les autres services avec.

                  Faux par défaut parce que servir des fichiers statiques ne coûte
                  rien, et qu'une limite posée sans raison finit par gêner un
                  usage légitime avant de gêner qui que ce soit d'autre.
                '';
              };

              paths = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "/api" ];
                description = ''
                  Chemins comptés, en préfixe — `/api` attrape aussi
                  `/api/quoi/que/ce/soit`.

                  Liste VIDE : c'est toute l'application qui est comptée, fichiers
                  statiques compris. Préférer désigner les chemins coûteux, pour
                  qu'un visiteur qui charge une page ne consomme pas le quota qui
                  protège l'API.
                '';
              };

              rate = lib.mkOption {
                type = lib.types.str;
                default = "60r/m";
                description = ''
                  Débit soutenu autorisé, au format de nginx.

                  Une requête par seconde en moyenne : très au-delà de ce qu'un
                  humain devant une interface produit, et cent fois en dessous de
                  ce qu'un script obtiendrait sans limite.
                '';
              };

              burst = lib.mkOption {
                type = lib.types.ints.positive;
                default = 20;
                description = ''
                  Requêtes acceptées d'un coup au-delà du débit, servies sans
                  délai puis décomptées.

                  Sans rafale, une interface qui émet trois appels au chargement
                  d'une page se ferait refuser les deux derniers. C'est ce réglage
                  qui distingue « limiter les abus » de « casser l'application ».
                '';
              };
            };
          };

          config.domain = lib.mkDefault name;
        }
      )
    );
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.apps exige systemSettings.proxy.enable : c'est lui qui porte nginx et l'obtention des certificats.";
      }
      {
        assertion = lib.all (a: !a.public) (lib.attrValues cfg) || config.systemSettings.cloudflared.enable;
        message = "systemSettings.apps : une application marquée `public` a besoin de systemSettings.cloudflared.enable pour être routée, aucun port n'étant ouvert sur la box.";
      }
      {
        assertion = lib.all (a: a.containers != { }) (lib.attrValues cfg);
        message = "systemSettings.apps : une application sans conteneur ne sert rien, et son vhost renverrait une erreur de passerelle.";
      }
      {
        # Déduire le point d'entrée quand il y en a plusieurs reviendrait à le
        # tirer de l'ordre alphabétique : le jour où un conteneur `api` s'ajoute
        # devant `frontend`, nginx se mettrait à servir l'API à la racine, sans
        # un mot.
        assertion = lib.all (a: a.entrypoint != null || lib.length (lib.attrNames a.containers) == 1) (
          lib.attrValues cfg
        );
        message = "systemSettings.apps : `entrypoint` est requis dès qu'une application a plusieurs conteneurs — c'est celui que nginx sert.";
      }
      {
        assertion = lib.all (a: a.entrypoint == null || a.containers ? ${a.entrypoint}) (
          lib.attrValues cfg
        );
        message = "systemSettings.apps : `entrypoint` doit nommer un conteneur déclaré dans `containers`.";
      }
      {
        # Le point d'entrée est le seul conteneur publié : sans son port, rien
        # ne dit à nginx où frapper. Les autres peuvent l'omettre — ils n'ouvrent
        # rien sur le host et leurs pairs les joignent sur le port qu'ils veulent.
        assertion = lib.all (a: a.containers.${entrypointOf a}.port != null) (lib.attrValues cfg);
        message = "systemSettings.apps : le conteneur désigné par `entrypoint` doit déclarer son `port`, c'est celui que nginx sert.";
      }
      {
        assertion = lib.all (a: lib.all (p: lib.hasPrefix "/" p) a.rateLimit.paths) (lib.attrValues cfg);
        message = "systemSettings.apps : les `rateLimit.paths` sont des chemins nginx, ils commencent par « / ».";
      }
      {
        assertion = lib.all (
          a: lib.all (c: lib.all (d: a.containers ? ${d}) c.dependsOn) (lib.attrValues a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : un `dependsOn` doit nommer un conteneur de la MÊME application.";
      }
      {
        # systemd RÉSOUT les cycles de dépendance en cassant un lien au hasard,
        # sans échouer. L'ordre obtenu n'est alors ni celui qu'on a écrit ni un
        # ordre stable, et le symptôme n'apparaît qu'un démarrage sur deux.
        assertion = lib.all (
          a: lib.all (n: !(lib.elem n a.containers.${n}.dependsOn)) (lib.attrNames a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : un conteneur ne peut pas dépendre de lui-même.";
      }
      {
        # Ces noms deviennent des noms de conteneurs, de réseaux, d'interfaces et
        # d'identifiants nginx. Les restreindre ici donne un message clair, là où
        # un caractère exotique produirait sinon une erreur de podman au
        # démarrage — ou pire, passerait.
        assertion = lib.all (n: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]*" n != null) (
          names ++ lib.concatMap (a: lib.attrNames a.containers) (lib.attrValues cfg)
        );
        message = "systemSettings.apps : les noms d'applications et de conteneurs se limitent à des lettres, chiffres, tirets et soulignés, et commencent par un caractère alphanumérique.";
      }
      {
        # Quinze caractères, limite du noyau pour un nom d'interface. Au-delà,
        # podman refuse de créer le pont et l'application ne démarre pas — sans
        # que le message dise que le nom de l'application est en cause.
        assertion = lib.all (n: lib.stringLength (bridgeOf n) <= 15) names;
        message = "systemSettings.apps : le nom d'une application à plusieurs conteneurs doit tenir en 12 caractères — le pont réseau s'appelle `br-<nom>` et le noyau limite un nom d'interface à 15.";
      }
      {
        assertion = lib.all (
          a: lib.all (c: lib.all (v: lib.hasPrefix "/" v.target) c.volumes) (lib.attrValues a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : la `target` d'un montage est un chemin absolu dans le conteneur.";
      }
      {
        # CE QU'UN MONTAGE MAL PLACÉ COÛTE. `/var/lib/containers` en écriture,
        # c'est la faculté de réécrire l'image de n'importe quel autre conteneur
        # de la machine. `/nix` en écriture, c'est réécrire les binaires du
        # système. `/` se passe de commentaire. Ce sont des évasions complètes,
        # pas des fuites d'information, et rien dans une chaîne
        # `source:destination` ne les distinguait d'un montage anodin.
        assertion = lib.all (
          a:
          lib.all (
            c:
            lib.all (
              v:
              !(lib.elem v.source [
                "/"
                "/etc"
                "/boot"
                "/nix"
                "/run"
              ])
              && !(lib.any (p: v.source == p || lib.hasPrefix "${p}/" v.source) [
                "/dev"
                "/proc"
                "/sys"
                "/var/lib/containers"
              ])
            ) c.volumes
          ) (lib.attrValues a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : ce montage donne au conteneur un répertoire système du host — racine, /nix, /etc, /run, /boot, /dev, /proc, /sys ou l'espace de stockage des conteneurs. Aucune application web n'en a besoin, et un accès en écriture à l'un d'eux vaut une évasion complète.";
      }
      {
        # `extraInputRules` n'existe QUE pour le pare-feu nftables : le backend
        # iptables l'ignore EN SILENCE. La règle qui ouvre le DNS entre
        # conteneurs disparaîtrait alors sans un mot, et le symptôme serait une
        # application qui ne démarre pas — plusieurs heures de diagnostic pour
        # une ligne jamais appliquée.
        assertion = config.networking.nftables.enable;
        message = "systemSettings.apps : une application à plusieurs conteneurs exige networking.nftables.enable, seul backend où la règle ouvrant le DNS entre conteneurs est appliquée.";
      }
    ];

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
          ports = lib.optional c.isEntrypoint "127.0.0.1:${toString portOf.${c.appName}}:${toString c.container.port}";

          networks = lib.singleton (networkOf c.appName);

          dependsOn = map (n: containerKey c.appName n) c.container.dependsOn;

          inherit (c.container) cmd user;

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
      (map (
        appName:
        {
          ${networkUnitOf appName} = {
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
            # dépend pas seulement des règles de pare-feu posées plus bas.
            script =
              let
                net = lib.escapeShellArg (networkOf appName);
                bridge = lib.escapeShellArg (bridgeOf appName);
                opts = lib.escapeShellArgs [
                  "--opt"
                  "com.docker.network.bridge.name=${bridgeOf appName}"
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
                  echo "réseau ${networkOf appName} : pont « $actual » au lieu de « ${bridgeOf appName} », recréation" >&2
                  # `-f` : les conteneurs attachés sont détachés d'office. Ils
                  # sont `partOf` cette unité (cf. plus bas), donc systemd les a
                  # déjà arrêtés avant d'arriver ici, et les redémarrera après.
                  ${podmanBin} network rm -f ${net}
                  create
                fi
              '';
          };
        }
      ) names)

      # Chaque conteneur attend son réseau. `requires` et pas seulement `after` :
      # un conteneur démarré sans son réseau ne dégrade pas, il échoue.
      #
      # `partOf` en plus, et c'est ce qui rend la recréation du réseau sûre :
      # arrêter ou redémarrer l'unité du réseau arrête d'abord les conteneurs qui
      # en font partie, et les relance ensuite. Sans lui, une recréation
      # arracherait le pont sous des conteneurs qui continueraient de tourner en
      # croyant être connectés.
      ++ (map (
        c:
        {
          ${unitOf c.key} = {
            after = [ "${networkUnitOf c.appName}.service" ];
            requires = [ "${networkUnitOf c.appName}.service" ];
            partOf = [ "${networkUnitOf c.appName}.service" ];
          };
        }
      ) allContainers)

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

    # DNS ENTRE CONTENEURS, ouvert dans le pare-feu du host.
    #
    # Sans cette règle, un conteneur ne résout AUCUN de ses pairs, et le seul
    # symptôme est une application qui ne démarre pas. Le diagnostic est
    # trompeur de bout en bout : le réseau existe, `dns_enabled` est vrai,
    # aardvark-dns tourne et écoute sur la passerelle, son fichier de zone
    # contient les bons noms et les bons alias — et rien ne répond.
    #
    # POURQUOI. La requête part du conteneur vers la passerelle du pont, qui est
    # une adresse DU HOST : elle arrive donc dans la chaîne d'entrée du pare-feu,
    # pas dans une chaîne de traversée. netavark pose bien un `accept` pour
    # elle, mais DANS SA PROPRE TABLE — et en nftables, toutes les tables
    # accrochées au même point sont évaluées, un `drop` dans l'une annulant un
    # `accept` dans l'autre. `nixos-fw` jette le paquet avant qu'aardvark-dns le
    # voie.
    #
    # C'est le miroir de l'avertissement de modules/system/network, qui prévoit
    # qu'un conteneur devienne joignable en CONTOURNANT le pare-feu. Ici c'est
    # l'inverse : le pare-feu bloque un trafic interne légitime.
    #
    # Portée aussi étroite que possible : seulement le port 53, et seulement
    # depuis les ponts NOMMÉMENT désignés — pas un joker `podman*`, qui
    # couvrirait aussi le réseau par défaut de podman et tout pont futur créé
    # hors de ce module. Les conteneurs n'obtiennent aucun autre accès au host.
    networking.firewall.extraInputRules = lib.mkIf (cfg != { }) (
      lib.concatMapStrings (n: ''
        iifname "${bridgeOf n}" meta l4proto { tcp, udp } th dport 53 accept comment "resolution des conteneurs de ${n}"
      '') names
    );

    # TRAFIC ENTRE CONTENEURS, dans la chaîne de TRAVERSÉE cette fois.
    #
    # Même cause que la règle ci-dessus, autre chaîne — et il faut les deux. Une
    # requête vers aardvark-dns vise la passerelle du pont, donc une adresse du
    # host : elle arrive en ENTRÉE. Une requête d'un conteneur vers un autre
    # traverse le host : elle passe par la chaîne de FORWARD, que
    # `networking.firewall.filterForward` fait jeter par défaut.
    #
    # Le symptôme est particulièrement trompeur : la résolution fonctionne, le
    # conteneur obtient bien l'adresse de son pair, ouvre une connexion — et
    # attend. Les paquets sont jetés sans refus, donc rien ne répond jamais et
    # l'appelant meurt sur un délai. Vu ici comme un 504 après soixante
    # secondes, le délai par défaut de nginx, sans qu'aucune requête n'ait jamais
    # atteint le service visé.
    #
    # UNE RÈGLE PAR APPLICATION, entrée et sortie sur LE MÊME pont — et c'est le
    # point le plus important de tout ce module.
    #
    # La version précédente écrivait `iifname "podman*" oifname "podman*"`, sur
    # l'affirmation que netavark isolait déjà les applications entre elles.
    # C'ÉTAIT FAUX : sa page de manuel dit que l'option `isolate` « bloque le
    # trafic entre les réseaux QUI L'ONT ACTIVÉE », et elle n'est pas active par
    # défaut. Rien ne séparait donc deux applications sinon le `drop` de
    # `nixos-fw` — précisément celui que cette règle levait. Une base de données
    # d'une application devenait joignable depuis le conteneur d'une autre.
    #
    # Nommer les ponts permet d'exiger que la source ET la destination soient sur
    # le même, ce qui rend le cloisonnement structurel plutôt que déclaratif.
    # Combiné à `isolate=true` posé à la création, deux barrières indépendantes
    # le tiennent.
    #
    # CE QUI RESTE FERMÉ, à dessein : la sortie vers internet depuis un
    # conteneur. Aucune application n'en a besoin aujourd'hui, et le jour où
    # l'une en aura besoin, elle échouera bruyamment — plutôt que de disposer en
    # silence d'un accès que personne ne lui a accordé.
    # `mkForce` ET C'EST OBLIGATOIRE ICI, pour une raison qui n'a rien à voir
    # avec ce module. `modules/system/server/vpn/wireguard` force déjà cette
    # option, parce que `networking.nat` y écrit de son côté un
    # `ip saddr { <internalIPs> } accept` sans restriction de destination, qui
    # rouvrirait aux peers du tunnel tout le LAN. Une définition ordinaire posée
    # ici serait donc ÉCARTÉE EN SILENCE par ce force — constaté, la règle
    # n'apparaissait pas dans le ruleset produit et le symptôme était le même
    # qu'avant le correctif.
    #
    # Deux définitions de MÊME priorité fusionnent entre elles tout en excluant
    # celles de priorité normale : forcer des deux côtés garde donc les règles du
    # tunnel ET celles-ci, sans laisser revenir celle du module amont.
    #
    # À RETENIR si un troisième module doit un jour poser des règles de
    # traversée : il devra forcer lui aussi, sans quoi il disparaîtra sans un
    # mot. Vérifier le ruleset produit, pas l'intention.
    networking.firewall.extraForwardRules = lib.mkIf (cfg != { }) (
      lib.mkForce (
        lib.concatMapStrings (n: ''
          iifname "${bridgeOf n}" oifname "${bridgeOf n}" accept comment "trafic interne a ${n}"
        '') names
      )
    );

    # ZONES DE LIMITATION, déclarées au niveau `http` — nginx n'en accepte pas
    # ailleurs.
    #
    # La clé est `$real_client_ip` et NON `$binary_remote_addr`, et c'est la
    # décision qui fait tout ici. Le trafic public arrive par cloudflared, donc
    # depuis 127.0.0.1 : compter par adresse de connexion mettrait TOUS les
    # visiteurs venus d'internet dans le même seau. Un seul abus les ferait tous
    # refuser, et l'abuseur ne serait pas isolé une seconde. La variable vient
    # des `map` de modules/system/server/proxy, qui la dérivent de
    # `CF-Connecting-IP` — un en-tête que l'edge de Cloudflare RÉÉCRIT, donc non
    # falsifiable par l'appelant.
    #
    # `mkAfter` n'est PAS cosmétique : nginx compile la clé d'une zone au moment
    # où il lit la directive, et refuse de démarrer sur une variable qu'il n'a
    # pas encore vue. Ces lignes doivent donc passer APRÈS le `map` qui définit
    # `$real_client_ip`.
    services.nginx.commonHttpConfig = lib.mkIf (limitedApps != [ ]) (
      lib.mkAfter (
        # 429 et non le 503 par défaut : le premier dit « tu vas trop vite », le
        # second « le service est en panne ». Un client bien élevé sait ralentir
        # sur le premier.
        ''
          limit_req_status 429;
        ''
        + lib.concatMapStrings (
          n: "limit_req_zone $real_client_ip zone=${zoneOf n}:10m rate=${cfg.${n}.rateLimit.rate};\n"
        ) limitedApps
      )
    );

    services.nginx.virtualHosts = lib.mapAttrs' (
      name: app: lib.nameValuePair app.domain (myLib.mkTlsVhost { locations = locationsOf name app; })
    ) cfg;

    # Une entrée par application publique dans le tunnel déjà existant.
    systemSettings.cloudflared.ingress = lib.listToAttrs (
      map (app: lib.nameValuePair app.domain "https://127.0.0.1:443") (
        lib.filter (a: a.public) (lib.attrValues cfg)
      )
    );
  };
}
