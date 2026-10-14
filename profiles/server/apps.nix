{ config, ... }:

# Applications web servies depuis des images de conteneurs.
let
  domain = import ./domain.nix;
  wireguard = config.systemSettings.vpn.wireguard;

  # Sources admises sur les services réservés à TES appareils dans le tunnel
  # (le coffre, MyETF), pas aux téléphones de la famille : les peers marqués
  # `trusted` (cf. vpn.nix).
  #
  # Plus la source sous laquelle think SE VOIT elle-même, pour la sonde de
  # surveillance seule : elle vise 10.8.0.1 mais ressort masquée en adresse du
  # LAN (cf. `selfSource` dans modules/system/server/vpn/wireguard).
  mesAppareils = wireguard.trustedSources ++ [ wireguard.selfSource ];
in
{
  systemSettings = {
    # PORTS DE BOUCLAGE FIGÉS (`hostPort`), ceux qu'attribuait jusque-là l'ordre
    # alphabétique. Écrits pour qu'une application ajoutée ne renumérote plus
    # les autres. 8085 est laissé libre à dessein : il revient à `stage`,
    # déclarée dans le dépôt privé sans `hostPort`, que l'attribution
    # automatique y place (premier port libre).
    # Portfolio, servi depuis une image construite par GitHub Actions à chaque
    # poussée sur `main` du dépôt du site. think ne détient aucune source : elle
    # tire une image et la fait tourner, c'est tout.
    #
    # Le digest se relève dans la sortie du run qui a publié l'image. Mettre à
    # jour le site = pousser, remplacer la ligne ci-dessous, rebuild.
    apps."portfolio" = {
      hostPort = 8083;

      # LA SEULE SONDE QUI VÉRIFIE LE CHEMIN PUBLIC COMPLET, et elle vaut à
      # elle seule les quatre autres pour ça.
      #
      # Les autres visent des noms que dnsmasq réécrit vers le LAN (cf.
      # `dns.overrides`) : elles tapent sur nginx en direct et ne traversent
      # jamais le tunnel, donc une panne de cloudflared les laisse toutes au
      # vert. L'apex, lui, n'a AUCUNE réécriture — volontairement. La requête
      # sort jusqu'à l'edge Cloudflare et redescend par le tunnel, exactement
      # comme celle d'un visiteur.
      #
      # NE PAS ajouter d'override dnsmasq pour ce nom : ce serait raccourcir
      # le trajet, donc supprimer ce que cette sonde est seule à vérifier.
      #
      # `http_2xx` et non `http_authelia` : le portfolio est public, aucun
      # portail devant. Et il répond 200 sur `/` sans redirection de locale,
      # vérifié — `next-intl` sert ici la langue par défaut à la racine.
      probe = { };

      inherit domain;

      # Un seul conteneur, donc pas d'`entrypoint` à désigner et aucun réseau
      # posé : il n'y a personne à résoudre.
      containers.web = {
        image = "ghcr.io/nchpg/portfolio@sha256:1bf19ec8da2104d05b862f71d1e8578376ce56b2715957bb3e4a1ad7b794e678";
        # Next en mode `standalone` écoute sur 3000 (cf. le Dockerfile du site).
        port = 3000;

        # PAS un secret, malgré son nom : ce jeton est servi dans un
        # `<meta name="google-site-verification">` du HTML, donc lisible par
        # quiconque affiche la source. Et le connaître ne permet à personne de
        # revendiquer le domaine — Google émet un jeton DIFFÉRENT par compte, la
        # difficulté étant de le placer sur le site, pas de le deviner. Il peut
        # donc rester en clair, là où `environmentFiles` serait requis pour une
        # vraie valeur sensible.
        #
        # Les variables `NEXT_PUBLIC_*` du site ne sont PAS ici, et ce n'est pas
        # un oubli : Next les remplace textuellement pendant `npm run build`,
        # donc les poser à l'exécution n'aurait aucun effet. Elles vivent dans
        # les `build-args` du workflow.
        environment.GOOGLE_SITE_VERIFICATION = "TfARlD-WI-dO71XO0G7bcmm5VvA_ra5idC-HK-Nd9qM";
      };
    };

    # RLkart : simulateur de karting piloté par apprentissage par renforcement.
    # Deux conteneurs, traduction directe de son `docker-compose.yml`.
    #
    # `frontend` sert les fichiers statiques et porte son propre nginx, qui
    # proxifie `/generate` et `/simulate` vers `http://backend:8000`. Cette
    # ligne-là fonctionne SANS ÊTRE TOUCHÉE : les deux conteneurs partagent le
    # réseau de l'application et s'y résolvent par leur nom.
    #
    # Ce que ça change par rapport au compose : `backend` ne publie plus
    # `8000:8000`. Il n'ouvre RIEN sur le host, donc plus personne sur le LAN
    # ne peut appeler l'API en court-circuitant nginx. Seul `frontend` est
    # publié, sur la boucle locale.
    apps."rlkart" = {
      hostPort = 8084;

      # RLkart, publié sur internet exactement comme le portfolio et qui
      # n'avait AUCUNE sonde — le seul des six noms publics dans ce cas.
      #
      # Ça compte plus que pour les autres, parce que c'est une application
      # en CONTENEUR : rien d'autre ne la surveille de près. Un service
      # systemd qui meurt se voit, un conteneur qui redémarre en boucle
      # reste `active` (cf. `ServiceRedemarreEnBoucle`, qui couvre la
      # boucle) et un conteneur qui répond des erreurs ne se voit QUE
      # d'ici.
      #
      # Comme le portfolio, ce nom n'a pas de réécriture dnsmasq : la
      # requête sort jusqu'à l'edge Cloudflare et redescend par le tunnel,
      # donc la sonde vérifie le chemin public complet et pas seulement
      # nginx. Ne pas ajouter d'override pour ce nom.
      #
      # `/` et non `/generate` ou `/simulate` : ces deux-là déclenchent un
      # calcul côté serveur et sont limités en débit à dessein. Une sonde
      # qui les appellerait chaque minute consommerait le quota censé
      # protéger la machine.
      probe = { };

      domain = "rlkart.${domain}";
      entrypoint = "frontend";

      containers = {
        frontend = {
          image = "ghcr.io/nchpg/rlkart-frontend@sha256:5f7b09c3452b9b1502e2b8c108f48bad28d31ef577b190b691624b1b7f282cb2";
          # L'image officielle nginx écoute sur 80. Sous 1024, donc le module
          # lui rend `CAP_NET_BIND_SERVICE` — sans quoi elle ne peut pas se
          # lier, même en root.
          port = 80;

          # Son nginx résout `backend` À L'ANALYSE de sa configuration, pas à
          # chaque requête. Démarré en premier, il meurt sur
          # `host not found in upstream` et boucle indéfiniment.
          dependsOn = [ "backend" ];

          # L'image officielle nginx démarre en root, s'approprie ses
          # répertoires de cache, puis abandonne ses privilèges pour ses
          # processus de travail. Sans ces trois-là, elle meurt sur
          # `chown("/var/cache/nginx/client_temp", 101) failed`.
          #
          # C'est le signe qu'une variante `nginxinc/nginx-unprivileged`
          # rendrait tout ça inutile : elle tourne en utilisateur non
          # privilégié sur un port haut, donc sans aucune de ces capacités ni
          # `NET_BIND_SERVICE`. À envisager la prochaine fois qu'on touche à ce
          # Dockerfile.
          capabilities = [
            "CHOWN"
            "SETUID"
            "SETGID"
          ];
        };

        backend = {
          image = "ghcr.io/nchpg/rlkart-backend@sha256:939e1f49e41a5b1e3a2fdf298a4d4f1ccd892ae6b92da9f9805e5b6937d7429d";
          # Rien n'est publié sur le host pour ce conteneur — seul le point
          # d'entrée l'est. Le port est déclaré quand même parce qu'il dit la
          # vérité sur ce que l'image écoute, et que le module s'en sert pour
          # décider des capacités à accorder.
          port = 8000;
        };
      };

      # LE POINT QUI COMPTE SUR CETTE APPLICATION-CI. `/simulate` déclenche une
      # simulation physique côté serveur, et `/generate` fabrique un tracé :
      # deux chemins qui coûtent du processeur à chaque appel. Exposés sans
      # limite, c'est un robinet ouvert sur internet — quelques boucles
      # suffisent à saturer think, ce qui emporterait Nextcloud et le reste.
      #
      # Les chemins sont désignés plutôt que l'application entière : charger la
      # page ne doit pas consommer le quota qui protège le calcul.
      rateLimit = {
        enable = true;
        paths = [
          "/generate"
          "/simulate"
        ];
      };
    };

    # MNIST : un réseau de neurones convolutif écrit en C++ sans bibliothèque
    # d'apprentissage, avec son serveur HTTP dans le même binaire.
    #
    # UN SEUL CONTENEUR, contrairement à rlkart : il n'y a pas de nginx de
    # façade à mettre devant. Le binaire répond `public/index.html` sur toute
    # requête GET et réserve `POST /predict` à l'inférence, donc l'aiguillage
    # qui justifiait un frontend séparé là-bas n'existe pas ici.
    #
    # Les poids sont EMBARQUÉS dans l'image, copiés à la construction depuis
    # `mnist_cnn.model` (795 Ko). C'est ce qui rend cette application
    # compatible avec la sortie internet fermée du module : elle ne va rien
    # chercher au démarrage.
    apps."mnist" = {
      hostPort = 8081;

      # MNIST, pour la même raison que rlkart : une application en
      # conteneur que rien d'autre ne surveille de près. Elle est même plus
      # exposée à passer inaperçue, n'ayant qu'un seul processus — s'il
      # meurt au chargement du modèle, l'unité redémarre en boucle et le
      # seul symptôme visible ailleurs est une passerelle défaillante.
      #
      # `/` et non `/predict` : la sonde ne poste pas de corps JSON, et
      # celle qui consommerait le quota du chemin qu'elle protège serait à
      # l'envers. La racine suffit à conclure, parce que c'est LE MÊME
      # processus qui sert la page et l'inférence — il n'y a pas de façade
      # qui pourrait répondre 200 pendant que le modèle est mort.
      #
      # Comme les deux au-dessus, ce nom n'a pas de réécriture dnsmasq : la
      # requête sort jusqu'à l'edge Cloudflare et redescend par le tunnel,
      # donc la sonde couvre le chemin public complet. Ne pas en ajouter.
      probe = { };

      domain = "mnist.${domain}";

      containers.web = {
        image = "ghcr.io/nchpg/mnist-cnn-cpp@sha256:64d15f30c87fdcb4774aed39f2bb99cedda84fd50c45f559b82ce6f31e9b8dc1";

        # Le binaire écoute sur 8080, passé en argument par son `CMD`.
        # Au-dessus de 1024, donc aucune capacité à rendre — vérifié en
        # exécutant l'image avec `--cap-drop=ALL`, elle démarre et répond.
        port = 8080;

        # Non privilégié, et c'est VÉRIFIÉ et non supposé : le serveur ne fait
        # que lire son modèle et sa page sous /app, il n'écrit nulle part.
        # Beaucoup d'images en sont incapables sans volume préparé ; celle-ci
        # le supporte, autant le prendre.
        user = "1000:1000";

        # MESURÉ : 1,5 Mo au repos, 10 Mo après une série d'inférences. Le
        # plafond est vingt fois au-dessus — il ne gênera jamais un usage
        # normal, il est là pour qu'une fuite reste chez elle au lieu
        # d'envoyer le tueur de mémoire du noyau chercher PostgreSQL.
        memory = "256m";
      };

      # `/predict` SEUL, et pas l'application entière : c'est le seul chemin
      # qui fait tourner le réseau. Le reste est une page statique servie par
      # le même binaire, et la charger ne doit pas entamer le quota qui
      # protège le calcul.
      #
      # Le débit par défaut est très large pour cette application : une
      # inférence prend 17 ms mesurées, et l'interface n'appelle `/predict`
      # que sur un clic de bouton, jamais pendant le tracé. Personne
      # n'atteindra soixante appels par minute à la main.
      #
      # Pas de `proxyTimeout` pour la même raison : à 17 ms, les soixante
      # secondes par défaut de nginx sont hors de portée.
      rateLimit = {
        enable = true;
        paths = [ "/predict" ];
      };
    };

    # Traffic Vision : détection de véhicules et de plaques par YOLO, sur une
    # vidéo déposée dans la page.
    #
    # RIEN NE CALCULE ICI, et c'est ce qui distingue cette application de
    # mnist et de rlkart malgré les apparences. Le modèle (37 Mo) est
    # téléchargé par le navigateur du visiteur, qui fait tourner
    # onnxruntime-web sur sa propre machine : la vidéo ne quitte jamais son
    # appareil et think ne sert que des fichiers. D'où l'absence de
    # `rateLimit` — il n'existe aucun chemin coûteux à protéger, et une limite
    # posée sans raison gênerait un visiteur légitime avant qui que ce soit
    # d'autre.
    #
    # PRÉCONDITION HORS DÉPÔT, à poser avant le rebuild, comme pour les autres
    # applications publiques : le nom doit être routé dans le tunnel
    # (`cloudflared tunnel route dns <tunnel> trafficvision.nathanchampagne.com`
    # depuis gram, ou le CNAME proxifié équivalent chez Cloudflare). L'ingress
    # côté think est généré par le module, lui, et n'a rien à écrire ici.
    #
    # `traffic` et pas `trafficvision` : le nom de l'attribut donne celui du
    # pont réseau (`br-<nom>`), que le noyau limite à quinze caractères. Il est
    # interne — réseau, unités systemd, règles de pare-feu — et n'a pas à
    # suivre le domaine servi, qui reste complet juste en dessous.
    apps."traffic" = {
      hostPort = 8086;
      domain = "trafficvision.${domain}";

      containers.web = {
        image = "ghcr.io/nchpg/yolo-detection@sha256:7bce55e4c5397d3540dc38d2526bfe59dece26426a07b86004214c4cb6f8a2a0";

        # L'image est la variante `unprivileged` de nginx, choisie exactement
        # pour la remarque laissée sur le frontend de rlkart : elle tourne en
        # utilisateur non privilégié sur un port haut, donc AUCUNE capacité à
        # rendre — pas de CHOWN/SETUID/SETGID. Vérifié en l'exécutant avec
        # `--cap-drop=ALL`, elle démarre et sert la page.
        port = 8080;

        # MESURÉ avec podman : 4,8 Mo au repos, 5,1 Mo après plusieurs
        # téléchargements du modèle. Le plafond est vingt-cinq fois au-dessus
        # — il laisse aussi la place au cache de pages que ces gros fichiers
        # remplissent, qui est décompté ici mais récupérable sous pression.
        memory = "128m";
      };
    };

    # iSeg-2017 : segmentation des tissus cérébraux du nourrisson sur IRM
    # T1/T2, trois modèles de 72 Ko à 1,9 Mo selon la finesse voulue.
    #
    # MÊME MONTAGE QUE traffic ci-dessus et pour les mêmes raisons — page
    # statique, calcul chez le visiteur, donc pas de `rateLimit` — avec une
    # différence à connaître avant de toucher à sa configuration nginx : cette
    # page-là n'a PAS besoin d'isolation cross-origin. Son `app.js` fixe
    # `ort.env.wasm.numThreads = 1`, ce qui la dispense de SharedArrayBuffer et
    # donc des en-têtes COOP/COEP que l'autre réclame. Les deux images ne se
    # ressemblent pas par hasard, elles diffèrent sur ce point exprès.
    #
    # Elle installe aussi un service worker, qui la rend utilisable hors ligne
    # après une visite. Rien à prévoir ici : il est servi depuis le répertoire
    # d'où il est enregistré, donc sa portée couvre le site sans en-tête
    # `Service-Worker-Allowed`.
    #
    # PRÉCONDITION HORS DÉPÔT, à poser avant le rebuild : le nom doit être
    # routé dans le tunnel (`cloudflared tunnel route dns <tunnel>
    # iseg2017.nathanchampagne.com` depuis gram).
    apps."iseg2017" = {
      hostPort = 8080;
      domain = "iseg2017.${domain}";

      containers.web = {
        image = "ghcr.io/nchpg/iseg-2017@sha256:e0b54b079669ad0bb7cad2bf9d64baed066de45689ca618c49f36612e3f03aba";

        # `iseg-2017` en minuscules dans le nom d'image, alors que le dépôt
        # s'appelle `iSeg-2017` : ghcr.io refuse les majuscules.
        #
        # Même variante `unprivileged` de nginx que traffic, donc aucune
        # capacité à rendre. Vérifié en exécutant l'image avec `--cap-drop=ALL`
        # et `--security-opt=no-new-privileges`, elle démarre et sert la page.
        port = 8080;

        # MESURÉ avec podman : 5,4 Mo au repos, 4,8 Mo après une série de
        # téléchargements des modèles et des IRM d'exemple.
        memory = "128m";
      };
    };

    # MyETF : analyse de portefeuilles d'ETF, servie depuis l'image que
    # GitHub Actions publie à chaque poussée sur `main` du dépôt Nchpg/MyETF.
    #
    # JOIGNABLE PAR LE TUNNEL WIREGUARD ET RIEN D'AUTRE, comme le coffre :
    # `public = false` ne pose aucune route dans cloudflared, et nginx refuse
    # toute source hors de tes appareils. Ce sont tes positions et tes
    # comptes, la famille n'a pas à y accéder.
    #
    # Aucun enregistrement DNS à créer : le joker `*.vpn.nathanchampagne.com`
    # pointe déjà vers 10.8.0.1 chez Cloudflare, en « DNS only ».
    apps."myetf" = {
      hostPort = 8082;

      # MyETF, réservée au tunnel comme le coffre : la sonde part de think,
      # dont l'adresse est dans `mesAppareils` pour cette raison. Elle vise
      # 10.8.0.1 par le nom public, donc elle couvre aussi le joker DNS
      # `*.vpn.` chez Cloudflare.
      probe = { };

      domain = "etf.vpn.${domain}";
      public = false;
      allowedNetworks = mesAppareils;

      # Les cotations viennent de Yahoo Finance, de la BCE, de justETF… à
      # chaque requête ou presque. Sans sortie, l'application démarre et
      # affiche des portefeuilles sans prix.
      internetAccess = true;

      containers.web = {
        image = "ghcr.io/nchpg/myetf@sha256:4fbfd4c90f69ed23c30644b24a7a920696839453f444a13eb5fa528f18b75115";
        # Next en mode `standalone` écoute sur 3000 (cf. le Dockerfile).
        port = 3000;

        # Le dépôt est privé, l'image aussi : contrairement au portfolio, le
        # tirage anonyme est refusé. Même jeton que le suivi de candidatures
        # (PAT classique, `read:packages` seul), qui couvre tous les packages
        # du compte.
        login = {
          username = "Nchpg";
          passwordKey = "stage/ghcr_token";
        };

        # Portefeuilles, comptes et cache des cotations. Volume NOMMÉ : podman
        # le remplit au premier montage depuis l'image, qui a déjà donné
        # `/app/data` à son utilisateur non root — rien à préparer sur le
        # host. À sauvegarder : c'est la seule copie de tes portefeuilles
        # hors de gram.
        volumes = [
          {
            source = "myetf-data";
            target = "/app/data";
            readOnly = false;
          }
        ];

        # Pas de BASIC_AUTH_* : la barrière est le tunnel et la liste
        # d'adresses ci-dessus. En local comme ici, l'application ne demande
        # rien sans ces variables.
      };
    };
  };
}
