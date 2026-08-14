{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Nextcloud servi par DEUX chemins, chacun protégé par le mécanisme qui lui
# convient :
#
#   navigateur    -> tunnel Cloudflare + Authelia (authentification interactive)
#   clients sync  -> WireGuard, puis nginx sur le nom interne (clés WireGuard)
#
# Pourquoi ce découpage : Authelia authentifie par redirection navigateur, ce que
# les clients de synchronisation ne savent pas suivre. Les faire passer par le
# tunnel obligerait à exempter `/remote.php/*` de la politique, c'est-à-dire à
# exposer WebDAV — précisément la surface qu'on cherche à protéger. En les
# routant par le VPN, aucune exemption n'est nécessaire nulle part.
let
  cfg = config.systemSettings.nextcloud;
  authelia = config.systemSettings.authelia;
  mail = config.systemSettings.mail;

  # Réglages communs aux unités qui appellent `occ`.
  #
  # Le `LoadCredential` n'est pas facultatif dès qu'un `secretFile` existe : le
  # wrapper nextcloud-occ vérifie `CREDENTIALS_DIRECTORY` et, s'il ne le trouve
  # pas, se relance par `systemd-run` — ce que l'utilisateur `nextcloud` n'a pas
  # le droit de faire. La commande échoue alors sur un « Access denied » sans
  # rapport apparent avec Nextcloud.
  occServiceConfig = {
    Type = "oneshot";
    User = "nextcloud";
    LoadCredential = lib.optional (
      config.services.nextcloud.secretFile != null
    ) "secret_file:${config.services.nextcloud.secretFile}";
  };
in
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

          CE QUE ÇA NE COUVRE PAS : un lien fabriqué par un chemin absent de la
          liste ci-dessous repartirait avec le nom interne. Le défaut se voit
          immédiatement — le lien affiche son hôte — mais il faut savoir le
          reconnaître.
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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.hostName != null;
        message = "systemSettings.nextcloud.hostName est requis : c'est le nom servi, et celui d'après lequel Nextcloud fabrique ses URL.";
      }
      {
        # Le vhost et le certificat viennent de modules/system/server/proxy.
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.nextcloud exige systemSettings.proxy.enable : c'est lui qui porte nginx et l'obtention des certificats.";
      }
      {
        # Une application dans les deux listes serait appliquée deux fois, dans
        # un ordre qui ne dit rien de l'intention.
        assertion = lib.intersectLists cfg.enabledApps cfg.disabledApps == [ ];
        message = "systemSettings.nextcloud : ${lib.concatStringsSep ", " (lib.intersectLists cfg.enabledApps cfg.disabledApps)} figure à la fois dans enabledApps et disabledApps.";
      }
      {
        # Tous ces noms traversent le contrôle d'Authelia, y compris ceux que ses
        # règles laissent passer. Or Authelia REFUSE (400) toute URL hors des
        # domaines de session qu'il connaît, et nginx traduit ce code inattendu
        # en 500 : un nom placé hors du domaine du cookie casserait le chemin
        # sans que rien ne le signale avant la première requête réelle.
        #
        # Les gardes sur null ne sont pas décoratives : toutes les assertions
        # s'évaluent, y compris quand une précédente échoue.
        assertion =
          !authelia.enable
          || authelia.domain == null
          || lib.all (
            host: host == authelia.domain || lib.hasSuffix ".${authelia.domain}" host
          ) cfg.extraHostNames;
        message = "systemSettings.nextcloud.extraHostNames : tous doivent être sous systemSettings.authelia.domain (${toString authelia.domain}) — Authelia rejette les URL hors de ses domaines de session, et nginx renvoie alors 500.";
      }
    ];

    sops.secrets."nextcloud/admin_pass" = {
      owner = "nextcloud";
    };

    # Contournement du portail sur les seuls chemins de partage public.
    #
    # `mkBefore` n'est PAS cosmétique : la première règle qui correspond gagne,
    # et celle qui met `hostName` en `two_factor` — sans `networks`, donc
    # attrapant toute origine — est justement celle qui bloque un destinataire
    # extérieur. Sans priorité, l'ordre de fusion des listes entre modules ne
    # garantit rien et l'option n'aurait d'effet qu'au hasard de l'évaluation.
    #
    # Passer AVANT les contournements du VPN est sans conséquence : ils sont
    # eux-mêmes des `bypass`, et cette règle-ci est plus étroite qu'eux.
    #
    # Déclaré ici plutôt que dans le profil pour que l'option fasse ce qu'elle
    # annonce. Le profil garde une note à l'endroit où les autres règles sont
    # listées, l'ordre effectif devant rester lisible d'un seul endroit.
    systemSettings.authelia.rules = lib.mkBefore (
      lib.optional (cfg.publicSharing.enable && authelia.enable) {
        domain = cfg.hostName;
        policy = "bypass";
        resources = cfg.publicSharing.autheliaResources;
      }
    );

    services.nextcloud = {
      enable = true;
      # Version majeure épinglée : les migrations de schéma sont irréversibles,
      # un saut de majeure au hasard d'un bump de nixpkgs se découvrirait après
      # coup et sans retour possible.
      package = pkgs-stable.nextcloud33;

      hostName = cfg.hostName;
      https = true;
      inherit (cfg) maxUploadSize;

      # Verrouillage de fichiers et cache mémoire. Sans lui, Nextcloud se plaint
      # dans sa page d'état et les synchronisations concurrentes se marchent
      # dessus.
      configureRedis = true;

      database.createLocally = true;

      # Réglages d'opcache, en mkDefault pour rester surchargeables. Les deux
      # premiers sont ceux que Nextcloud réclame dans sa page d'état, les défauts
      # de PHP étant taillés pour une application autrement plus petite.
      phpOptions = {
        # 8 par défaut, saturé par le nombre de chaînes qu'embarque Nextcloud :
        # au-delà, elles cessent d'être partagées entre processus et chacun refait
        # le travail. 32 ne suffisait pas non plus.
        "opcache.interned_strings_buffer" = lib.mkDefault "64";
        "opcache.memory_consumption" = lib.mkDefault "256";

        # Spécifique à NixOS et sans risque : opcache vérifie sinon la date de
        # chaque fichier à chaque requête, soit des milliers d'appels système
        # pour rien. Le store est immuable, et une mise à jour produit un nouveau
        # chemin donc un nouveau cache, plus un redémarrage de php-fpm puisque
        # son unité change — le cache ne peut pas rester périmé.
        "opcache.validate_timestamps" = lib.mkDefault "0";
      };

      config = {
        dbtype = "pgsql";
        adminuser = cfg.adminUser;
        # Mot de passe d'AMORÇAGE uniquement : le module amont ne s'en sert que
        # dans le `occ maintenance:install` initial. Le changer depuis l'interface
        # fonctionne normalement et aucun rebuild ne le réécrit.
        #
        # Si l'accès est perdu, la reprise se fait en SSH et sans courriel :
        #   sudo -u nextcloud nextcloud-occ user:resetpassword admin
        adminpassFile = config.sops.secrets."nextcloud/admin_pass".path;
      };

      settings = {
        # `hostName` y est déjà ajouté par le module amont ; on complète avec les
        # noms supplémentaires, sinon Nextcloud rejette toute requête qui les
        # emprunte par un « untrusted domain » peu explicite.
        trusted_domains = cfg.extraHostNames;
        trusted_proxies = [
          "127.0.0.1"
          "::1"
        ];

        # Le tunnel termine le TLS chez Cloudflare et parle ensuite à nginx en
        # local : sans cette réécriture, Nextcloud fabriquerait des URL en http://
        # et les redirections casseraient.
        overwriteprotocol = "https";

        # LE point délicat des deux chemins : la réécriture ci-dessus n'est
        # correcte que pour le trafic venant du tunnel, et serait fausse pour
        # celui du VPN, qui arrive directement sur nginx. On la restreint aux
        # requêtes issues de la boucle locale, c'est-à-dire à cloudflared.
        #
        # NE PAS l'élargir pour corriger les liens de partage fabriqués depuis le
        # VPN. La tentation est réelle — `overwritehost` existe pour ça — mais sa
        # portée est l'ADRESSE SOURCE, qui ne distingue pas l'application mobile
        # du navigateur venus du même tunnel : le nom interne cesserait alors
        # d'être navigable. C'est le rôle de `publicSharing.canonicalLinkHost`,
        # qui agit sur les seuls points d'entrée où le lien se fabrique.
        overwritecondaddr = "^127\\.0\\.0\\.1$";

        # URL de base quand il n'y a PAS de requête HTTP dont l'hériter : le
        # cron et `occ`. Sans elle, Nextcloud retombe sur `http://localhost`,
        # et c'est ce que fabriquaient les liens partis de la tâche de fond —
        # notifications, rappels de partage, courriels de réinitialisation.
        # Injoignables pour le destinataire, et en clair.
        #
        # Effet de bord à connaître : les vérifications d'installation
        # (`occ setupchecks`) s'en servent aussi pour se joindre elles-mêmes.
        # Elles resteront en échec, mais pour une autre raison — Authelia leur
        # répond une redirection vers le portail, la source étant l'adresse LAN
        # du serveur, retirée des règles de contournement. Ce sont des FAUX
        # positifs : le point de terminaison WebDAV, les en-têtes de sécurité,
        # `.well-known` et les fichiers `.mjs` sont tous correctement servis par
        # nginx, ce qu'on peut vérifier depuis un client authentifié.
        "overwrite.cli.url" = "https://${cfg.hostName}";

        # ffmpeg pour le fournisseur d'aperçus `Movie`. Le chemin du binaire est
        # donné EXPLICITEMENT plutôt que laissé à la recherche dans le PATH, et
        # c'est le fond d'un bug qui a duré.
        #
        # La version précédente posait `env[PATH]` sur le pool php-fpm, ce qui
        # est nécessaire en principe : PHP-FPM efface l'environnement de ses
        # processus de travail, si bien qu'un PATH posé sur l'unité systemd
        # resterait sur le seul processus maître. Sauf que le module amont
        # définit DÉJÀ ce PATH, par l'option `phpEnv.PATH`. Le fichier de pool
        # se retrouvait avec deux lignes `env[PATH]`, dont la seconde — celle de
        # l'amont, sans ffmpeg — écrasait la nôtre. Aucun conflit côté Nix, les
        # deux valeurs venant d'options différentes : l'échec était SILENCIEUX
        # et le module avait l'air correct.
        #
        # `preview_ffmpeg_path` sort de cette course. Nextcloud le lit en
        # priorité et ne cherche dans le PATH que s'il est absent (vérifié dans
        # `PreviewManager.php`). Rien à réordonner, rien à forcer.
        #
        # Ce que ça n'explique PAS : les échecs sur `.wmv` venus du CRON, qui a
        # bien ffmpeg dans son PATH. Ceux-là tiennent au fichier lui-même.
        preview_ffmpeg_path = "${pkgs-stable.ffmpeg-headless}/bin/ffmpeg";

        # Cf. l'option chunkSizeMiB.
        max_chunk_size = cfg.chunkSizeMiB * 1024 * 1024;

        # Sans région par défaut, Nextcloud refuse les numéros de téléphone non
        # préfixés et le signale dans sa page d'état.
        default_phone_region = "FR";

        # Heure (UTC) à laquelle Nextcloud groupe ses tâches de fond lourdes.
        # Sans ce réglage il les lance n'importe quand, y compris pendant que
        # quelqu'un consulte ses photos.
        maintenance_window_start = 2;

        # Valeur SYSTÈME et non réglage d'application, contrairement à ce que
        # laisse croire le nom : `MandatoryTwoFactor` fait
        # `getSystemValue('twofactor_enforced', 'false') === 'true'`. Un `occ
        # config:app:set` écrirait un paramètre que personne ne lit. Et c'est la
        # CHAÎNE "true" : la comparaison est stricte.
        twofactor_enforced = if cfg.enforceTwoFactor then "true" else "false";

        # Le lecteur de journal intégré ne sait lire qu'un fichier, alors que le
        # module amont envoie tout au syslog : l'application `logreader` restait
        # activée mais inutilisable. Le journal systemd reste alimenté par les
        # erreurs de php-fpm et de nginx.
        log_type = "file";

        # Liste reprise du défaut amont, PLUS `Movie` : sans lui une vidéo n'a
        # aucune vignette, le défaut supposant ffmpeg absent. On le fournit juste
        # en dessous.
        enabledPreviewProviders = [
          "OC\\Preview\\PNG"
          "OC\\Preview\\JPEG"
          "OC\\Preview\\GIF"
          "OC\\Preview\\BMP"
          "OC\\Preview\\XBitmap"
          "OC\\Preview\\Krita"
          "OC\\Preview\\WebP"
          "OC\\Preview\\MarkDown"
          "OC\\Preview\\TXT"
          "OC\\Preview\\OpenDocument"
          "OC\\Preview\\Movie"
        ];
      }
      # `force_*` écrase le choix de chacun, `default_*` ne sert que de valeur
      # initiale : ce ne sont pas les mêmes clés, d'où l'aiguillage.
      // lib.optionalAttrs (cfg.language != null) (
        if cfg.forceLanguage then
          { force_language = cfg.language; }
        else
          { default_language = cfg.language; }
      )
      // lib.optionalAttrs (cfg.locale != null) (
        if cfg.forceLanguage then { force_locale = cfg.locale; } else { default_locale = cfg.locale; }
      )
      # Le mot de passe n'est PAS ici : `settings` finit dans le store. Il arrive
      # par `secretFile`, un JSON fusionné dans config.php à l'activation.
      // lib.optionalAttrs mail.enable {
        mail_smtpmode = "smtp";
        mail_smtphost = mail.host;
        mail_smtpport = mail.port;
        # Nextcloud attend "ssl" pour du TLS implicite, "tls" pour du STARTTLS.
        mail_smtpsecure = if mail.port == 465 then "ssl" else "tls";
        mail_smtpauth = true;
        mail_smtpname = mail.user;
        # Nextcloud veut l'expéditeur en DEUX morceaux, partie locale et domaine.
        mail_from_address = lib.head (lib.splitString "@" mail.from);
        mail_domain = lib.last (lib.splitString "@" mail.from);
      };

      extraApps =
        lib.optionalAttrs cfg.previews.pregenerate {
          inherit (pkgs-stable.nextcloud33Packages.apps) previewgenerator;
        }
        // lib.optionalAttrs (cfg.theming.customCss != "") {
          inherit (pkgs-stable.nextcloud33Packages.apps) theming_customcss;
        };

      secretFile = lib.mkIf mail.enable config.sops.templates."nextcloud-secrets.json".path;
    };

    # Le gabarit substitue le mot de passe à l'activation, sans jamais l'écrire
    # dans le store. Appartient à nextcloud, seul à devoir le lire — d'où
    # l'absence de ce service dans le groupe `smtp`.
    sops.templates."nextcloud-secrets.json" = lib.mkIf mail.enable {
      owner = "nextcloud";
      content = builtins.toJSON {
        mail_smtppassword = config.sops.placeholder.${mail.passwordKey};
      };
    };

    # La tâche de fond fabrique aussi des aperçus. Elle tourne en PHP CLI et non
    # derrière fpm, donc le PATH de l'unité lui suffit.
    systemd.services.nextcloud-cron.path = [ pkgs-stable.ffmpeg-headless ];

    # `preview:pre-generate` ne traite que ce qui a été ajouté depuis le dernier
    # passage, il est donc rapide en régime établi. Le RATTRAPAGE initial se
    # lance à la main, une seule fois :
    #
    #   sudo nextcloud-occ preview:generate-all
    #
    # En ROOT et non en `sudo -u nextcloud` : le wrapper se relance par
    # `systemd-run` pour charger les credentials, ce que l'utilisateur
    # `nextcloud` n'a pas le droit de demander. Même cause que le
    # `LoadCredential` d'`occServiceConfig`.
    #
    # Sur une bibliothèque déjà remplie, comptez des heures : à lancer dans un
    # tmux, pas dans une session SSH qu'une coupure interromprait.
    systemd.services.nextcloud-preview-pregenerate = lib.mkIf cfg.previews.pregenerate {
      description = "Fabrique à l'avance les miniatures Nextcloud";
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      path = [ pkgs-stable.ffmpeg-headless ];
      # `occServiceConfig` et non un bloc à part : c'est lui qui porte le
      # `LoadCredential` sans lequel le wrapper `occ` échoue sur un « Access
      # denied » qui ne nomme ni Nextcloud ni les credentials. Cette unité s'en
      # passait, et échouait donc à chaque passage du minuteur.
      serviceConfig = occServiceConfig // {
        # Longue et sans urgence : elle ne doit pas disputer le processeur aux
        # requêtes des utilisateurs.
        Nice = 19;
        IOSchedulingClass = "idle";
      };
      script = "${lib.getExe config.services.nextcloud.occ} preview:pre-generate";
    };

    systemd.timers.nextcloud-preview-pregenerate = lib.mkIf cfg.previews.pregenerate {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.previews.interval;
        Persistent = true;
      };
    };

    # Un seul appel à occ pour toute la liste, et non un par application : chacun
    # démarre un interpréteur PHP complet et charge Nextcloud, ce qui se
    # compterait en dizaines de secondes à chaque activation.
    #
    # `|| true` volontaire : une application déjà désactivée, ou protégée par la
    # liste `alwaysEnabled` de Nextcloud, fait sortir occ en erreur, et ce n'est
    # pas une raison d'interrompre l'activation du système. Il ne masque plus
    # l'échec du wrapper lui-même, réglé par le LoadCredential.
    systemd.services.nextcloud-apps = lib.mkIf (cfg.disabledApps != [ ] || cfg.enabledApps != [ ]) {
      description = "Applique l'état des applications Nextcloud";
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = occServiceConfig;
      script =
        let
          occ = lib.getExe config.services.nextcloud.occ;
        in
        lib.optionalString (cfg.enabledApps != [ ]) ''
          ${occ} app:enable ${lib.concatStringsSep " " cfg.enabledApps} || true
        ''
        + lib.optionalString (cfg.disabledApps != [ ]) ''
          ${occ} app:disable ${lib.concatStringsSep " " cfg.disabledApps} || true
        '';
    };

    # Réglages de partage. Par `occ` et non par `settings` : ce sont des valeurs
    # d'APPLICATION, rangées dans `oc_appconfig` sous l'application `core`, et un
    # `settings` les écrirait dans config.php où personne ne les lit. Même
    # distinction que pour le thème juste en dessous — vérifier la source plutôt
    # que le nom.
    systemd.services.nextcloud-sharing = lib.mkIf cfg.publicSharing.enable {
      description = "Applique les réglages de partage public Nextcloud";
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = occServiceConfig;
      script =
        let
          occ = lib.getExe config.services.nextcloud.occ;
          set = key: value: "${occ} config:app:set core ${key} --value ${lib.escapeShellArg value}";
        in
        lib.concatStringsSep "\n" (
          if cfg.publicSharing.linkExpireDays != null then
            [
              (set "shareapi_default_expire_date" "yes")
              (set "shareapi_expire_after_n_days" (toString cfg.publicSharing.linkExpireDays))
              # Un DÉFAUT, pas un plafond : sans cette ligne à `no`, la date
              # posée au-dessus deviendrait indépassable et un partage qui doit
              # durer obligerait à rebuild.
              (set "shareapi_enforce_expire_date" "no")
            ]
          else
            # Remise à zéro explicite, le mécanisme étant à sens unique : cesser
            # d'écrire une valeur d'appconfig ne l'efface pas, et une expiration
            # posée puis retirée du profil resterait en place indéfiniment.
            [ (set "shareapi_default_expire_date" "no") ]
        );
    };

    # Le thème passe par `occ` et non par `settings` : ce sont des réglages
    # d'APPLICATION, contrairement à `twofactor_enforced` qui, malgré son nom,
    # était une valeur système. Vérifier la source plutôt que le nom, à chaque
    # fois.
    #
    # La feuille de style est appliquée INDÉPENDAMMENT des couleurs. Masquer des
    # éléments d'interface et choisir une palette sont deux sujets sans rapport,
    # et les avoir couplés obligeait à subir un thème pour garder des masquages —
    # ou l'inverse.
    systemd.services.nextcloud-theming = lib.mkIf (cfg.theming.enable || cfg.theming.customCss != "") {
      description = "Applique le thème Nextcloud";
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = occServiceConfig;
      script =
        let
          occ = lib.getExe config.services.nextcloud.occ;
          set = key: value: "${occ} theming:config ${key} ${lib.escapeShellArg value}";

          # Les valeurs de thème vivent dans la BASE de Nextcloud, pas dans la
          # configuration : cesser de les écrire ne les efface pas. Sans cette
          # remise à zéro, désactiver `theming.enable` laissait l'ancienne
          # palette en place indéfiniment — mécanisme à SENS UNIQUE, exactement
          # comme `disabledApps`, et pour la même raison.
          reset = key: "${occ} theming:config ${key} --reset";
          themedKeys = [
            "primary_color"
            "background_color"
            "background"
            "disable-user-theming"
            "name"
          ];
        in
        lib.concatStringsSep "\n" (
          lib.optionals (!cfg.theming.enable) (map reset themedKeys)
          ++ lib.optionals cfg.theming.enable (
            [
              (set "primary_color" cfg.theming.primaryColor)
              (set "background_color" cfg.theming.backgroundColor)
              # `backgroundColor` est la valeur MAGIQUE que la commande
              # reconnaît pour effacer l'image de fond et laisser l'aplat. À
              # ne pas confondre avec la constante interne
              # `BACKGROUND_COLOR = 'color'`, qui gouverne le choix par
              # utilisateur : passer `color` ici fait échouer la commande sur
              # « The image file needs to be provided as an absolute path ».
              (set "background" "backgroundColor")
              (set "disable-user-theming" (if cfg.theming.lockUserTheming then "yes" else "no"))
            ]
            ++ lib.optional (cfg.theming.name != null) (set "name" cfg.theming.name)
          )
          ++ lib.optionals (cfg.theming.customCss != "") [
            "${occ} config:app:set theming_customcss customcss --value ${lib.escapeShellArg cfg.theming.customCss}"
            # Le cachebuster VERSIONNE l'URL de la feuille : sans lui, les
            # navigateurs resservent celle qu'ils ont en cache. Dérivé du
            # contenu, il ne bouge que quand la feuille change.
            "${occ} config:app:set theming_customcss cachebuster --value ${
              builtins.substring 0 8 (builtins.hashString "sha256" cfg.theming.customCss)
            }"
          ]
        );
    };

    # PostgreSQL sort de ses valeurs d'usine, taillées pour tenir sur une machine
    # minuscule. En mkDefault, et légitime ici parce que `database.createLocally`
    # implique une instance dédiée à Nextcloud.
    #
    # Le gain reste modeste, la base étant petite et déjà en cache noyau. C'est
    # `random_page_cost` qui compte le plus : sa valeur d'origine (4) décrit un
    # disque à plateaux et pousse le planificateur à éviter les index sur un SSD.
    services.postgresql.settings = {
      shared_buffers = lib.mkDefault "2GB";
      effective_cache_size = lib.mkDefault "8GB";
      work_mem = lib.mkDefault "16MB";
      maintenance_work_mem = lib.mkDefault "512MB";
      random_page_cost = lib.mkDefault 1.1;
    };

    services.nginx.commonHttpConfig = lib.mkMerge [
      # Hôte annoncé à PHP, pour que le lien de partage porte le nom PUBLIC même
      # quand il naît d'une requête arrivée par un nom interne.
      #
      # `default $http_host` : partout ailleurs, exactement la valeur que nginx
      # aurait transmise de toute façon. Ce `map` ne change donc RIEN hors des
      # chemins nommés — c'est ce qui garde le nom interne pleinement navigable,
      # là où `overwritehost` aurait réécrit toutes les pages.
      #
      # `$request_uri` et SURTOUT PAS `$uri`, et c'est tout le sujet. La location
      # PHP du module amont finit par `try_files $fastcgi_script_name =404`, qui
      # RÉÉCRIT `$uri` vers le fichier trouvé dès qu'il existe. Or les paramètres
      # FastCGI sont construits en phase de contenu, donc APRÈS : au moment où
      # nginx évalue ce `map`, `$uri` ne vaut plus
      # `/ocs/v2.php/apps/files_sharing/api/v1/shares` mais `/ocs/v2.php`, et
      # aucun motif ne correspond plus. Le lien repartait alors avec le nom
      # interne, sans que rien ne le signale — reproduit puis vérifié sur une
      # location identique à celle du module amont, avec un PHP réel derrière.
      #
      # `$request_uri` porte l'URL d'origine et ne bouge jamais, ni par
      # `try_files` ni par une redirection interne. Il transporte aussi la chaîne
      # de requête, sans conséquence : les motifs sont ancrés sur `^` et ne
      # regardent que le début du chemin.
      #
      # À NE PAS confondre avec le `map` de la limitation plus bas, qui garde
      # `$uri` à dessein : `limit_req` s'évalue en phase de PRÉ-ACCÈS, avant
      # `try_files`, et c'est justement `$uri` qui y suit les redirections
      # internes et permet de ne compter qu'une fois.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.canonicalLinkHost) ''
        map $request_uri $nextcloud_link_host {
          default $http_host;
        ${lib.concatMapStrings (path: "  ${path} ${cfg.hostName};\n") cfg.publicSharing.canonicalLinkPaths}}
      '')

      # Zone de limitation des chemins de partage public — les seuls de
      # l'instance que le portail ne garde plus.
      #
      # La clé est `$real_client_ip` et non `$remote_addr` : derrière le tunnel,
      # toutes les connexions viennent de cloudflared en 127.0.0.1, et une zone
      # clavetée dessus mettrait la terre entière dans le même seau — la première
      # requête d'un attaquant ferait tomber le partage pour tout le monde.
      #
      # `mkAfter` pour la même raison que dans modules/system/server/apps : nginx
      # compile la clé d'une zone au moment où il lit la directive et refuse de
      # démarrer sur une variable qu'il n'a pas encore vue. Ces lignes doivent
      # passer après le `map` qui définit `$real_client_ip`.
      #
      # `limit_req_status` n'est PAS posé ici : le module apps l'écrit déjà au
      # niveau http quand une de ses applications est limitée, et cette directive
      # ne tolère pas le doublon dans un même contexte. Il est posé sur le vhost
      # plus bas, où il vaut sans dépendre de ce que fait l'autre module.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.rateLimit.enable) (lib.mkAfter ''
          # `volatile` désactive la mise en cache de la valeur, et c'est ce qui
          # rend le comptage EXACT. `/s/<jeton>` n'est pas servi tel quel : la
          # location `/` du module amont fait `try_files … /index.php$request_uri`,
          # donc nginx repart en redirection interne et rejoue la phase où
          # `limit_req` s'applique. Avec la valeur en cache, la même requête
          # consommerait deux jetons ; sans cache, la seconde passe voit
          # `$uri = /index.php/s/<jeton>`, qui ne correspond à rien ici.
          #
          # D'où aussi le choix de `$uri` plutôt que `$request_uri` : c'est le
          # premier qui suit la réécriture interne, le second reste figé sur
          # l'URL d'origine et remettrait le double comptage.
          #
          # Une clé VIDE désactive la limite pour la requête (comportement
          # documenté de limit_req) : tout ce qui n'est pas un chemin de partage
          # traverse sans être compté, ressources statiques comprises.
          map $uri $nextcloud_share_client {
            volatile;
            default         "";
            ~^/s/           $real_client_ip;
            ~^/public\.php  $real_client_ip;
          }

          limit_req_zone $nextcloud_share_client zone=nextcloud_share:10m rate=${cfg.publicSharing.rateLimit.rate};
        ''))
    ];

    # Le module Nextcloud crée déjà ce vhost ; on n'y ajoute que le TLS et les
    # noms supplémentaires. enableACME couvre automatiquement les serverAliases,
    # donc un seul certificat porte l'ensemble.
    services.nginx.virtualHosts.${cfg.hostName} = lib.mkMerge [
      (myLib.mkTlsVhost { serverAliases = cfg.extraHostNames; })

      # Au niveau du SERVEUR et non d'une location : les chemins concernés sont
      # servis par plusieurs locations du module amont (la générique pour `/s/`,
      # celle des scripts PHP pour `/public.php`), et c'est le `map` ci-dessus
      # qui désigne ce qui compte. Une location dédiée obligerait à réécrire le
      # passage à php-fpm, pour un résultat plus fragile.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.rateLimit.enable) {
        extraConfig = ''
          limit_req zone=nextcloud_share burst=${toString cfg.publicSharing.rateLimit.burst} nodelay;
          # 429 et non le 503 par défaut : le premier dit « tu vas trop vite », le
          # second « le service est en panne ».
          limit_req_status 429;
        '';
      })

      # L'en-tête que Nextcloud lit pour connaître l'adresse du client, ÉCRASÉ
      # avec une valeur que l'appelant ne choisit pas (cf. les `map` de
      # modules/system/server/proxy).
      #
      # Sans ça, `trusted_proxies` en dessous se retourne contre nous : sur le
      # chemin du tunnel, la connexion vient de cloudflared en 127.0.0.1, donc
      # d'un proxy déclaré de confiance, et Nextcloud prend alors l'adresse dans
      # `X-Forwarded-For`. Or nginx passe à php-fpm tous les en-têtes du client
      # tels quels, et Cloudflare AJOUTE l'adresse réelle derrière celle qu'on
      # lui envoie au lieu de la remplacer. Résultat : l'appelant choisissait son
      # adresse, donc les journaux, et surtout le compteur anti-force-brute de
      # Nextcloud, qui compte par IP et se remettait à zéro à chaque requête.
      #
      # Un `fastcgi_param` explicite l'emporte sur l'en-tête du client : nginx
      # écarte de la liste qu'il transmet les noms déjà définis ici. C'est le
      # même mécanisme que la parade classique à httpoxy.
      #
      # Dans CETTE location et pas au niveau du serveur : une location qui
      # déclare ses propres `fastcgi_param` n'hérite pas de ceux du parent, et
      # celle-ci en déclare (module Nextcloud amont).
      {
        locations."~ \\.php(?:$|/)".extraConfig = ''
          fastcgi_param HTTP_X_FORWARDED_FOR $real_client_ip;
        '';
      }

      # Hôte annoncé à PHP, cf. le `map` plus bas — la valeur vaut `$http_host`
      # partout sauf sur les points d'entrée où le lien de partage se fabrique.
      #
      # MÊME MÉCANISME que la ligne juste au-dessus, et il vaut d'être redit :
      # un `fastcgi_param` explicite l'emporte sur l'en-tête du client, nginx
      # écartant de la liste qu'il transmet les noms déjà définis ici. Sans ça
      # les deux valeurs partiraient et PHP garderait la première.
      #
      # Dans CETTE location précisément : elle déclare ses propres
      # `fastcgi_param`, elle n'hérite donc pas de ceux d'un bloc parent.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.canonicalLinkHost) {
        locations."~ \\.php(?:$|/)".extraConfig = ''
          fastcgi_param HTTP_HOST $nextcloud_link_host;
        '';
      })

      # Portail d'authentification devant le vhost, quand il est activé.
      #
      # UN seul nom, deux chemins, et c'est Authelia qui les distingue — sur
      # l'adresse source, par ses règles `networks` (cf. le profil). Depuis le
      # LAN ou le VPN il contourne, ce qui permet aux clients de synchronisation
      # de fonctionner sans qu'on exempte `/remote.php/*` ; depuis le tunnel il
      # exige deux facteurs. La discrimination se fait donc sur des règles qu'il
      # sait évaluer, et pas dans du nginx écrit à la main.
      #
      # Le socle (directive auth_request et point de contrôle) vient du module
      # authelia ; seul le traitement du 401 est propre à Nextcloud.
      (lib.mkIf authelia.enable authelia.nginxAuthRequest)

      (lib.mkIf authelia.enable {
        extraConfig = ''
          # Le 401 ne peut PAS être réécrit en 302 sans discernement, comme le
          # fait l'extrait générique d'Authelia. Deux sources en produisent ici :
          #
          #   - Authelia quand il refuse : il joint un en-tête Location vers le
          #     portail, et il FAUT rediriger.
          #   - Nextcloud lui-même, quand un client WebDAV non authentifié
          #     interroge /remote.php/dav : 401 + WWW-Authenticate, le protocole
          #     normal, qu'il ne faut PAS toucher.
          #
          # Sur le chemin interne Authelia contourne, donc $redirection_url est
          # vide : sans cette distinction, le 401 de Nextcloud devenait un 302
          # avec un Location VIDE et toutes les applications de synchronisation
          # échouaient sur une « erreur HTTP inconnue ».
          error_page 401 = @authelia_or_app;
        '';

        locations."@authelia_or_app".extraConfig = ''
          internal;

          # Un Location renseigné ne peut venir que d'Authelia : on redirige.
          if ($redirection_url != "") {
            return 302 $redirection_url;
          }

          # Sinon le 401 appartient à l'application, et on le laisse repartir.
          # Son en-tête WWW-Authenticate n'est PAS réémis ici : celui de
          # Nextcloud survit à l'interception, et l'ajouter le faisait partir en
          # double.
          #
          # Les en-têtes de sécurité qui suivent, eux, sont bien RECOPIÉS de ceux
          # que le module Nextcloud pose sur le vhost : un `add_header` dans une
          # location REMPLACE toute la liste du parent au lieu de s'y ajouter, et
          # sans eux la réponse 401 partirait sans X-Frame-Options ni
          # X-Content-Type-Options (attrapé par gixy, l'analyseur que NixOS passe
          # sur la config). Couplage assumé : si l'amont change sa liste, celle-ci
          # devra suivre.
          #
          # HSTS comprise, et c'est celle qui compte : un client de synchro non
          # authentifié reçoit un 401 à chaque requête, donc la quasi-totalité du
          # trafic WebDAV passe par ici. L'oublier revenait à ne poser l'en-tête
          # que sur les réponses des sessions déjà ouvertes.
          add_header X-Content-Type-Options nosniff always;
          add_header X-Robots-Tag "noindex, nofollow" always;
          add_header X-Permitted-Cross-Domain-Policies none always;
          add_header X-Frame-Options sameorigin always;
          add_header Referrer-Policy no-referrer always;
          add_header Strict-Transport-Security "max-age=${toString config.services.nextcloud.nginx.hstsMaxAge}; includeSubDomains" always;
          return 401;
        '';
      })
    ];
  };
}
