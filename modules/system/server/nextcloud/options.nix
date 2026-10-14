{
  config,
  lib,
  ...
}:

# Options de Nextcloud. Cf. default.nix pour le montage d'ensemble.
{
  options.systemSettings.nextcloud = {
    enable = lib.mkEnableOption "Nextcloud (PostgreSQL et Redis locaux)";

    hostName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "cloud.exemple.fr";
      description = ''
        Nom PUBLIC, celui que sert le tunnel. C'est aussi celui que Nextcloud
        emploie pour fabriquer ses URL (liens de partage, redirections), d'où le
        choix d'y mettre le nom public : un lien généré doit rester valable pour
        un destinataire extérieur.
      '';
    };

    extraHostNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "cloud.vpn.exemple.fr" ];
      description = ''
        Noms SUPPLÉMENTAIRES sous lesquels servir la même instance. Ajoutés en
        alias du vhost — donc couverts par le certificat, `enableACME` reprenant
        les `serverAliases` — et déclarés en domaines de confiance, faute de quoi
        Nextcloud rejette la requête par un « untrusted domain » peu explicite.

        L'usage prévu est un nom joignable par un chemin RÉSERVÉ, typiquement
        l'adresse du serveur dans un tunnel VPN, pour les clients de
        synchronisation : ils ne savent pas suivre une redirection
        d'authentification, il leur faut donc un nom qu'une règle laisse passer.

        `hostName` reste le nom que Nextcloud emploie pour fabriquer ses URL :
        un lien de partage doit rester valable pour un destinataire extérieur,
        qui n'a pas accès à ces chemins-là.
      '';
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Compte administrateur créé à la première initialisation.";
    };

    previews = {
      pregenerate = lib.mkEnableOption ''
        la fabrication des miniatures À L'AVANCE, par l'application
        previewgenerator et une tâche périodique.

        Sans elle, Nextcloud fabrique chaque miniature au moment où on la
        regarde. Redimensionner une photo de 12 mégapixels coûte bien plus qu'une
        requête ordinaire, et c'est ce qui décide qu'une galerie défile ou rame
      '';

      interval = lib.mkOption {
        type = lib.types.str;
        default = "*:0/30";
        description = "Fréquence de la pré-génération, au format `OnCalendar` de systemd.";
      };
    };

    enforceTwoFactor = lib.mkEnableOption ''
      l'obligation d'un second facteur pour TOUS les comptes Nextcloud.

      Distinct de celui d'Authelia, qui ne garde que le chemin public : le chemin
      interne, emprunté par le VPN et les applications de synchronisation, ne
      passe pas par le portail. Sans ce réglage, un compte n'y est donc protégé
      que par son mot de passe.

      Les applications mobiles et de bureau ne sont PAS concernées, elles
      utilisent des mots de passe d'application qui contournent le second facteur
      par conception. Chaque utilisateur devra en revanche enrôler un facteur à
      sa prochaine connexion par navigateur.

      Porte de secours si quelqu'un se bloque :
        sudo -u nextcloud nextcloud-occ twofactorauth:disable <utilisateur>
    '';

    publicSharing = {
      enable = lib.mkEnableOption ''
        les LIENS DE PARTAGE PUBLICS pour un destinataire extérieur.

        Sans ça ils ne fonctionnent pas. Un partage « à qui a le lien » suppose
        par définition quelqu'un qui n'a ni compte Authelia ni clé WireGuard :
        sa requête arrive par le tunnel, nginx voit 127.0.0.1, aucune règle
        `networks` ne s'applique et le portail le renvoie sur une page de
        connexion qu'il ne peut pas franchir.

        Ce que ça fait : place DEVANT les autres règles d'Authelia un
        contournement limité aux chemins de `autheliaResources`, et sur le seul
        `hostName`. Le reste de Nextcloud continue de passer par le portail —
        `/login`, `/settings`, `/apps/files`, et surtout `/remote.php`,
        c'est-à-dire le WebDAV qui s'ouvre avec un mot de passe de compte. C'est
        la ligne que l'en-tête de ce module refuse de franchir, et elle n'est pas
        franchie ici.

        CE QUI PROTÈGE UN PARTAGE une fois le portail écarté :
          - le jeton du lien, quinze caractères tirés du générateur sûr de
            Nextcloud, soit plus de 80 bits. Aucun point d'entrée ouvert ici ne
            liste les partages, il n'y a pas d'identifiant séquentiel, et un
            mauvais jeton répond 404 : l'énumération n'est pas praticable ;
          - les pages de partage partant avec `X-Robots-Tag: noindex, nofollow`,
            elles ne se retrouvent pas dans un moteur de recherche ;
          - `linkExpireDays`, qui borne la durée pendant laquelle un lien ayant
            fuité reste vivant — le mode de fuite RÉEL d'un lien de partage
            n'étant pas la force brute mais le transfert, l'historique de
            navigateur ou l'export de conversation ;
          - `rateLimit`, contre le martèlement des chemins ouverts.

        CE QU'ON PERD, à assumer : le code de `files_sharing` devient joignable
        depuis internet, là où le portail l'absorbait. Une faille
        d'authentification dans cette application-là serait donc exploitable.
        C'est irréductible — c'est exactement la surface qu'un lien public doit
        exposer — et ce qui l'atténue est `autoUpgrade`, qui applique les
        correctifs sans intervention.

        Les chemins ouverts restent gardés par Nextcloud LUI-MÊME : un point
        d'entrée de partage exige un jeton valide, tout le reste exige une
        session. Le portail était une SECONDE couche, et c'est elle seule qu'on
        retire, sur ces chemins-là uniquement
      '';

      linkExpireDays = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 60;
        description = ''
          Durée de vie par DÉFAUT d'un nouveau lien public, en jours. `null`
          laisse les liens sans expiration, ce qui est le défaut de Nextcloud.

          C'est la contrepartie la plus utile au retrait du portail, et celle qui
          ne coûte rien à l'usage : elle ne demande pas de transmettre un code au
          destinataire, elle borne simplement la fenêtre pendant laquelle un lien
          oublié dans une conversation reste exploitable.

          Une valeur par DÉFAUT et non imposée : `shareapi_enforce_expire_date`
          reste à `no`, donc la date se rallonge depuis l'interface quand un
          partage doit durer. Ne s'applique qu'aux liens créés ENSUITE, les
          partages existants gardent la leur.

          Sens UNIQUE, comme `disabledApps` : revenir à `null` remet bien
          `shareapi_default_expire_date` à `no`, mais désactiver `enable` tout
          court retire l'unité et laisse le réglage en place. Plus restrictif que
          l'inverse, donc sans danger — juste bon à savoir.
        '';
      };

      canonicalLinkHost = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Fabrique les liens de partage avec `hostName`, même quand le partage
          est créé par un `extraHostNames`.

          LE PROBLÈME QUE ÇA RÈGLE. Nextcloud construit ses URL absolues à
          partir de l'hôte de la requête en cours, et le champ `url` que renvoie
          l'API de partage n'y échappe pas — c'est un `linkToRouteAbsolute`. Un
          partage créé depuis l'application mobile, configurée sur le nom
          joignable par le seul VPN, sort donc en `https://cloud.vpn.…/s/<jeton>`.
          Ce nom ne résout que vers une adresse de tunnel : le destinataire, qui
          n'a pas le VPN, obtient un lien MORT, et rien ne le signale au moment
          de l'envoyer.

          COMMENT, et c'est le point qui décide de tout. On ne touche PAS à
          `overwritehost`, qui aurait été l'outil évident : sa portée est
          l'adresse source, donc il ne sait pas distinguer une application d'un
          navigateur venus du même tunnel. Il aurait réécrit les pages web
          servies sur le nom interne, qui aurait alors renvoyé vers le portail
          au premier lien suivi — le nom cessait d'être navigable — et cassé
          l'ajout d'un compte par « Login Flow v2 ».

          On agit donc au seul endroit où le lien se fabrique : nginx impose
          `HTTP_HOST` sur les points d'entrée OCS de l'application de partage,
          et nulle part ailleurs. Vérifié dans les sources de la version servie,
          `Request::getInsecureServerHost()` lit `HTTP_HOST` dès lors que la
          requête ne vient pas d'un proxy de confiance, ce qui est le cas par le
          VPN. Le reste de l'instance — pages web, WebDAV, tout le reste
          d'OCS — continue de voir le nom réellement demandé.

          Aucun effet sur les cookies : Nextcloud n'impose de domaine de session
          que si `cookie_domain` est configuré, ce qui n'est pas le cas, donc le
          navigateur garde la portée du nom qu'il a réellement visité.

          CE QUE ÇA NE COUVRE PAS : le lien affiché par l'INTERFACE WEB. Celle-ci
          ne lit pas le champ `url` du serveur, elle reconstruit le lien côté
          navigateur à partir de `window.location` (vérifié dans le bundle :
          `generateUrl('/s/{token}', …, { baseURL: getBaseUrl() })`). Un partage
          créé au navigateur sur le nom interne affiche donc ce nom. Pour couvrir
          ce cas-là, et lui seul, voir `canonicalLinkWebUi`. L'application
          mobile, elle, lit bien le champ `url` et bénéficie de cette option-ci.
        '';
      };

      canonicalLinkWebUi = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Fige l'hôte du lien de partage DANS L'INTERFACE WEB, en patchant le
          code compilé de Nextcloud.

          À DISTINGUER de `canonicalLinkHost`, qui agit sur l'API OCS (donc sur
          l'application mobile) par une réécriture nginx. Le navigateur, lui,
          n'utilise pas cette API : il fabrique le lien lui-même à partir de
          `window.location`, que rien côté serveur ne contrôle. Le seul point de
          prise est le bundle JavaScript.

          CE QUE ÇA FAIT : un override du paquet Nextcloud remplace, dans les
          bundles `dist/*.js`, le `baseURL` du seul appel qui construit le lien
          de partage — `generateUrl('/s/{token}', …, { baseURL: getBaseUrl() })`
          — par `hostName` en dur. Ciblé sur cet appel : la navigation reste
          relative, `extraHostNames` reste navigable sans portail, rien d'autre
          ne bouge.

          LE COÛT, à assumer pleinement. On patche du code MINIFIÉ, non
          contractuel, régénéré à chaque version de Nextcloud. Une garde au build
          compte les remplacements et FAIT ÉCHOUER la construction s'il en manque
          — le patch ne peut donc pas disparaître en silence. Mais la
          contrepartie est directe : le jour où une mise à jour de Nextcloud
          change ces bundles, le build échoue, et sur ce système `autoUpgrade`
          cesse d'aboutir jusqu'à ce que le motif soit réajusté (une alerte
          Discord le signale, l'ancienne génération continue de tourner). C'est
          une dette de maintenance délibérée, en échange d'un lien correct au
          navigateur quel que soit le nom visité.

          Laissé à `false` par défaut : le reste du module n'a aucun couplage à
          l'amont de cette nature, et l'imposer serait le trahir. À activer en
          connaissance de cause.
        '';
      };

      neutralNotFound = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Remplace la page d'erreur de Nextcloud par une page NEUTRE quand un
          jeton de partage n'existe pas ou a expiré.

          CE QUE ÇA FERME. Sans elle, `/s/<n_importe_quoi>` renvoie la page 404
          complète de Nextcloud, quinze kilo-octets qui divulguent la VERSION
          exacte (`"version":"33.0.6.2"`), la liste des applications installées
          et les chemins `/nix-apps/…` qui trahissent NixOS — le tout sans aucun
          jeton valide, donc à qui balaie internet. C'est une divulgation que le
          portail retenait avant l'ouverture des partages, et la version est
          précisément ce qui dit à un attaquant quelle faille essayer.

          CE QUE ÇA NE FERME PAS : la même page est servie à quiconque détient
          un VRAI lien. Cacher la version aux visiteurs légitimes est
          impossible, c'est la page de partage elle-même. On sort donc des
          balayages de masse, pas du champ de quelqu'un à qui l'on a déjà
          envoyé un partage.
        '';
      };

      canonicalLinkPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = [ "~^/ocs/v[12]\\.php/apps/files_sharing/" ];
        defaultText = lib.literalExpression "les points d'entrée OCS de l'application de partage";
        description = ''
          Chemins sur lesquels `canonicalLinkHost` impose `HTTP_HOST`, au format
          des motifs d'un `map` nginx — évalués sur `$request_uri`, cf. le
          commentaire du `map` pour pourquoi ce n'est pas `$uri`.

          UN SEUL suffit, et c'est volontaire. Le champ `url` d'un partage naît
          dans `ShareAPIController::formatShare`, servi par ces points d'entrée
          là, que l'application mobile comme le panneau de partage de l'interface
          web appellent tous les deux. Le courriel de `sharebymail` part de la
          même requête, il hérite donc du bon nom sans rien de plus.

          En LECTURE SEULE : chaque entrée est un endroit où Nextcloud se voit
          mentir sur l'hôte demandé. Élargir la liste se fait ici, en regardant
          ce que ça change pour les réponses concernées.
        '';
      };

      rateLimit = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Limite le débit de requêtes par adresse sur les chemins de partage.

            Ils sont les seuls de l'instance joignables sans authentification :
            sans plafond, ils constituent un robinet ouvert sur internet, aussi
            bien pour marteler le code d'un partage protégé que pour éprouver
            `files_sharing` à la recherche d'un défaut.

            La clé est `$real_client_ip` (cf. modules/system/server/proxy), pas
            `$remote_addr` : derrière le tunnel, toutes les connexions viennent
            de 127.0.0.1 et une zone clavetée dessus mettrait la terre entière
            dans le même seau.
          '';
        };

        rate = lib.mkOption {
          type = lib.types.str;
          default = "10r/s";
          description = ''
            Débit soutenu par adresse, au format de `limit_req_zone`.

            Large à dessein : le plafond vise l'abus, pas l'usage. Les ressources
            statiques de la page de partage n'y sont PAS soumises, et un
            téléchargement — même de plusieurs gigaoctets — ne compte que pour
            une requête, la limite portant sur leur nombre et non sur le débit.
          '';
        };

        burst = lib.mkOption {
          type = lib.types.ints.positive;
          default = 30;
          description = ''
            Rafale tolérée avant que le plafond ne morde, servie sans délai
            (`nodelay`). Absorbe l'ouverture d'un dossier, qui enchaîne quelques
            requêtes WebDAV d'un coup.
          '';
        };

        previewRate = lib.mkOption {
          type = lib.types.str;
          default = "40r/s";
          description = ''
            Débit par adresse pour les VIGNETTES de partage
            (`/apps/files_sharing/publicpreview/`), zone distincte de `rate`.

            Ces chemins sont ouverts sans portail mais échappaient à la limite
            générale : détenteur d'un lien vers un dossier fourni, on pouvait
            marteler la génération d'aperçus, chacun coûtant un redimensionnement
            d'image. Atténué par `previews.pregenerate` et l'arrondi des tailles
            aux puissances de quatre — quelques aperçus distincts par fichier,
            déjà fabriqués — mais un grand album laisse une charge soutenue
            possible.

            Plus HAUT que `rate` à dessein : une galerie charge quarante
            vignettes d'un coup, un plafond serré les couperait en carrés
            cassés. Le but est d'écrêter l'abus, pas l'affichage normal.
          '';
        };

        previewBurst = lib.mkOption {
          type = lib.types.ints.positive;
          default = 80;
          description = ''
            Rafale tolérée sur les vignettes avant que `previewRate` ne morde.
            Dimensionnée pour l'ouverture d'une galerie entière d'un coup.
          '';
        };
      };

      autheliaResources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = [
          # La page de partage, la soumission du mot de passe quand le partage en
          # porte un (/s/<jeton>/authenticate) et le téléchargement
          # (/s/<jeton>/download).
          "^/s/"
          "^/index\\.php/s/"

          # Point d'entrée public : le WebDAV de partage, par lequel la page
          # liste le contenu d'un dossier et par lequel un dépôt de fichiers
          # téléverse, plus les anciennes URL de téléchargement.
          "^/public\\.php"

          # Les DEUX seules routes publiques de l'application de partage : les
          # vignettes, et le point d'information hérité. Nommées une par une
          # plutôt qu'un `^/apps/files_sharing/` général, qui laisserait aussi
          # passer `settings/shareFolder`, `accept/{id}` et `api/externalShares`
          # — sans danger, Nextcloud exigeant une session dessus, mais sans
          # raison d'être joignables sans le portail. Liste relevée dans
          # apps/files_sharing/appinfo/routes.php.
          "^/apps/files_sharing/(publicpreview|shareinfo)"
          "^/index\\.php/apps/files_sharing/(publicpreview|shareinfo)"

          # Thème, favicon et manifeste : sans eux la page publique s'affiche
          # nue, alors qu'elle est ce qu'un destinataire voit de l'instance.
          #
          # Là encore les routes PUBLIQUES seulement. `^/apps/theming/` tout
          # court exposerait `ajax/uploadImage`, `ajax/updateStylesheet` et
          # `background/*` : réservées à l'administrateur et protégées par CSRF,
          # mais un point de téléversement n'a rien à faire hors du portail.
          "^/apps/theming/(theme|image|manifest|favicon|icon|img)/"
          "^/index\\.php/apps/theming/(theme|image|manifest|favicon|icon|img)/"

          # Redemandé quand la session anonyme expire pendant que la page reste
          # ouverte. Ne divulgue rien : un jeton CSRF ne vaut que pour la session
          # qui le demande, et celle-ci est anonyme.
          "^/csrftoken"
          "^/index\\.php/csrftoken"

          # Ressources statiques. Ce sont les MÊMES fichiers pour tout le monde,
          # servis avant toute notion de compte : les ouvrir ne divulgue que la
          # version de Nextcloud, que la page de partage annonce de toute façon.
          #
          # Ces préfixes correspondent à de vrais répertoires de l'arborescence
          # (`core/css`, `core/js`, `core/img`, `core/fonts`, `core/l10n`,
          # `core/vendor`, `dist`) et non à des routes — donc à des FICHIERS, que
          # nginx sert sans jamais entrer dans PHP. Les entrées `^/css/`, `^/js/`
          # et `^/apple-touch-icon` de la première rédaction ont été retirées :
          # rien ne répond dessus, et une ligne morte dans une liste de sécurité
          # se relit comme une ligne utile.
          #
          # `^/apps/[^/]+/(css|js|img|fonts|l10n)/` couvre les mêmes
          # sous-répertoires côté applications. Le seul chemin de cette forme qui
          # soit une ROUTE et non un fichier est `theming/img/{app}/{image}`
          # (recensé sur l'ensemble des routes livrées) : une icône thémée,
          # publique, déjà couverte au-dessus.
          "^/core/(css|js|img|fonts|l10n|vendor)/"
          "^/apps/[^/]+/(css|js|img|fonts|l10n)/"
          "^/dist/"
          "^/favicon\\.ico$"
        ];
        defaultText = lib.literalExpression "les chemins qu'emprunte une page de partage public";
        description = ''
          Chemins exemptés du portail quand `enable` est vrai, au format
          `resources` d'Authelia — des expressions régulières évaluées sur le
          chemin de la requête.

          Volontairement en LECTURE SEULE. Cette liste est une décision de
          sécurité : ce qui y entre cesse d'être protégé par le portail, et un
          ajout depuis un profil passerait inaperçu. L'élargir se fait ici, en
          regardant ce que la ligne ouvre.

          Ce qui n'y est PAS, et ne doit pas y venir : `/remote.php` (WebDAV par
          compte), `/ocs` (API, y compris celle qui liste les partages),
          `/login`, `/settings`, `/apps/files`.

          Ce n'est pas un contrat amont : une mise à jour majeure de Nextcloud
          peut déplacer une de ces URL, auquel cas la page de partage se met à
          rediriger vers le portail. Le journal d'Authelia en `debug` nomme alors
          le chemin refusé.
        '';
      };
    };

    language = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fr";
      description = ''
        Langue de l'interface, code ISO à deux lettres. S'applique aux NOUVEAUX
        comptes et à la page de connexion ; les comptes existants gardent la
        leur, sauf si `forceLanguage` est activé.
      '';
    };

    locale = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "fr_FR";
      description = ''
        Format des dates, des nombres et du premier jour de la semaine. Distinct
        de la langue : on peut vouloir une interface en anglais avec des dates au
        format français.
      '';
    };

    forceLanguage = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Impose la langue et le format à TOUS les comptes, sans possibilité de les
        changer. Uniformise, au prix du choix individuel.
      '';
    };

    theming = {
      enable = lib.mkEnableOption ''
        un thème en aplats de couleur, sans image de fond, dérivé du schéma
        stylix actif du host.

        À PESER avant d'activer : une palette de terminal n'est pas une palette
        d'interface web. Les couleurs d'un schéma sombre sont désaturées pour
        ressortir sur du noir ; posées sur l'interface CLAIRE de Nextcloud, elles
        donnent des accents délavés et sans contraste. Le thème natif, lui, a été
        éprouvé sur cette interface-là.

        N'affecte QUE les couleurs et le nom affiché : `customCss` s'applique
        indépendamment, un masquage d'élément n'ayant rien à voir avec une
        palette
      '';

      primaryColor = lib.mkOption {
        type = lib.types.str;
        default = "#${config.lib.stylix.colors.base0D}";
        defaultText = lib.literalExpression "la couleur d'accent du schéma stylix";
        description = ''
          Couleur des boutons, liens et éléments actifs.

          Le défaut suit stylix par cohérence avec le reste du système, mais
          c'est rarement le bon choix ici — cf. la réserve sur `enable`. Une
          teinte choisie pour cette interface, ou le bleu natif `#0082C9`,
          donnent un meilleur résultat.
        '';
      };

      backgroundColor = lib.mkOption {
        type = lib.types.str;
        default = "#${config.lib.stylix.colors.base00}";
        defaultText = lib.literalExpression "la couleur de fond du schéma stylix";
        description = ''
          Fond de l'interface. Remplace l'image livrée par Nextcloud, ce qui
          allège aussi le chargement des pages.
        '';
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Cloud familial";
        description = "Nom affiché à la place de « Nextcloud ». `null` conserve le défaut.";
      };

      customCss = lib.mkOption {
        type = lib.types.lines;
        default = "";
        example = "#contactsmenu { display: none !important; }";
        description = ''
          Feuille de style injectée dans toutes les pages, par l'application
          `theming_customcss` qui s'installe alors automatiquement.

          C'est le SEUL levier pour ce que le thème ne couvre pas : les icônes de
          la barre supérieure, ou le menu contacts qui appartient au cœur de
          Nextcloud et qu'aucune désactivation d'application ne retire.

          Les sélecteurs dépendent de la version de Nextcloud et ne sont pas un
          contrat : une mise à jour majeure peut les invalider, auquel cas la
          règle cesse de s'appliquer sans rien casser.
        '';
      };

      lockUserTheming = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Empêche chaque compte de choisir ses propres couleurs. Sans ça le thème
          posé ici n'est qu'un défaut, que le premier utilisateur venu remplace
          pour lui-même.
        '';
      };
    };

    enabledApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sharebymail" ];
      description = ''
        Applications à réactiver explicitement.

        Indispensable parce que le mécanisme est à SENS UNIQUE : `occ
        app:disable` ne sait que désactiver, donc retirer une entrée de
        `disabledApps` ne la rallume pas. Sans cette liste, la configuration
        prétendrait qu'une application est active alors qu'elle resterait
        éteinte, et l'écart ne se verrait qu'en interrogeant `occ app:list`.
      '';
    };

    disabledApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "dashboard" ];
      description = ''
        Applications livrées avec Nextcloud à désactiver.

        Ça compte pour les performances : une application activée enregistre ses
        routes et ses écouteurs d'événements à CHAQUE requête, y compris celles
        des clients de synchronisation qui ne s'en serviront jamais. Sur un
        processeur modeste, c'est le principal gisement une fois l'opcache réglé.

        Le module amont ne sait qu'activer (`extraApps`), d'où l'unité qui passe
        par `occ` après l'installation.
      '';
    };

    chunkSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 50;
      description = ''
        Taille maximale d'un morceau de téléversement, en Mio. C'est ce réglage
        qui neutralise le plafond de Cloudflare : leur plan gratuit refuse toute
        requête dont le corps dépasse 100 Mo.

        Les clients découpent bien leurs envois, mais le client desktop
        dimensionne ses morceaux tout seul, en visant une minute par morceau avec
        un maximum par défaut de 100 Mo : sur une bonne connexion montante il
        atterrit pile sur la limite et échoue par intermittence.

        50 Mio laisse une marge franche. Ne pas monter au-delà de 90, ni
        descendre trop bas — plus les morceaux sont petits, plus il y a
        d'allers-retours.
      '';
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = ''
        Plafond appliqué de NOTRE côté (`upload_max_filesize`, `post_max_size` et
        `client_max_body_size`). À ne pas confondre avec la limite de 100 Mo par
        requête de Cloudflare, qui ne concerne que le chemin du tunnel et que le
        découpage en morceaux contourne (cf. `chunkSizeMiB`).
      '';
    };
  };
}
