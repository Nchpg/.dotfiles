{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Vaultwarden : coffre-fort de mots de passe compatible avec les clients
# Bitwarden (navigateurs, Android, iOS, CLI), servi depuis cette maison.
#
# JOIGNABLE PAR LE TUNNEL WIREGUARD ET RIEN D'AUTRE, contrairement à Nextcloud
# et à Grafana qui sortent par cloudflared derrière Authelia. Deux raisons, et
# la seconde compte plus que la première :
#
#   - Aucune route n'est posée dans le tunnel Cloudflare (cf. la section
#     « publication » plus bas, qui n'écrit RIEN dans `cloudflared.ingress`), et
#     le nom ne résout que vers l'adresse de think DANS le tunnel. Sans clé
#     WireGuard, il n'y a même pas d'adresse à attaquer.
#   - nginx refuse en plus toute source hors `allowedNetworks`. C'est la
#     barrière qui reste debout le jour où un nom est ajouté au tunnel par
#     mégarde : la route existerait, mais cloudflared arrive en 127.0.0.1, qui
#     n'est pas dans la liste. Un service qui détient TOUS les mots de passe ne
#     doit pas dépendre d'une seule ligne de configuration ailleurs.
#
# CE QUE ÇA COÛTE : sans tunnel WireGuard monté, pas de coffre. Les clients
# Bitwarden gardent un cache local chiffré et continuent de remplir les
# formulaires hors ligne, mais aucune modification ne se synchronise. C'est le
# compromis explicitement demandé — « uniquement via VPN pour le moment ».
#
# VERSION À TENIR À JOUR, et ce n'est pas un conseil d'hygiène : c'est le mode
# d'échec le plus déroutant de ce service, constaté le 15 août 2026. Les clients
# Bitwarden — extension et application mobile — se mettent à jour TOUT SEULS,
# hors du flake.lock, tandis que le serveur reste figé sur l'entrée nixpkgs
# épinglée. Quand ils prennent de l'avance, ils réclament au serveur des champs
# qu'il n'émet pas encore, et le symptôme ne ressemble à rien de connu :
#
#   - le coffre web fonctionne parfaitement — il est SERVI par le serveur, donc
#     accordé avec lui par construction ;
#   - le CLI fonctionne aussi, il est plus tolérant ;
#   - l'extension et le mobile se connectent, synchronisent, reçoivent la
#     totalité du coffre (22 447 octets vérifiés dans le journal nginx) et
#     affichent un coffre VIDE, sans le moindre message d'erreur.
#
# On cherche donc du côté du compte, du réseau, du cache et des URI, alors que
# la donnée est arrivée et que rien n'est cassé. La bascule 1.36.0 -> 1.37.1 a
# tout réglé d'un coup. Si le coffre se vide à nouveau sur ces clients-là, la
# PREMIÈRE chose à regarder est l'écart de version, avant tout le reste.
#
# POUR LE PUBLIER PLUS TARD, si le besoin vient : ajouter le nom public à
# `cloudflared.ingress`, ajouter `127.0.0.1/32` à `allowedNetworks`, et poser
# une règle Authelia `two_factor` sur ce nom AVANT tout le reste. Ne pas faire
# les deux premiers sans le troisième : la page de connexion de Vaultwarden
# deviendrait un point de bourrage d'identifiants ouvert sur internet, et une
# fois le mot de passe maître deviné il n'y a plus de second rempart — c'est
# tout le coffre d'un coup.
let
  cfg = config.systemSettings.vaultwarden;
  mail = config.systemSettings.mail;
  wireguard = config.systemSettings.vpn.wireguard;

  # Port de BOUCLAGE, constante et non option : rien d'autre que nginx ne s'y
  # adresse, et personne à l'extérieur n'a de raison de connaître cette valeur.
  # Même parti pris que les ports de modules/system/server/monitoring.
  port = 8222;

  proxyPass = "http://127.0.0.1:${toString port}";

  # Répertoire de données, calculé COMME LE MODULE AMONT plutôt que recopié :
  # il dépend de `system.stateVersion`, les instances antérieures à la 24.11
  # gardant le nom historique `bitwarden_rs`. Une constante en dur ferait
  # chercher la base au mauvais endroit sur une machine plus ancienne, et la
  # sonde échouerait pour une raison sans rapport avec ce qu'elle surveille.
  dataDir = "/var/lib/${
    if lib.versionOlder config.system.stateVersion "24.11" then "bitwarden_rs" else "vaultwarden"
  }";

  # CONTRÔLE POSITIF DU KDF, et il faut comprendre pourquoi c'est une SONDE et
  # non un réglage.
  #
  # L'algorithme qui dérive la clé maître est une propriété du COMPTE, choisie
  # et appliquée par le client : changer d'algorithme suppose de re-chiffrer la
  # clé protégée avec une clé re-dérivée du mot de passe maître, que ce serveur
  # ne détient pas et ne doit jamais détenir. Aucune option Nix ne peut donc
  # l'imposer — c'est le chiffrement de bout en bout qui l'interdit, pas une
  # lacune du module.
  #
  # Ce qui reste possible est de VÉRIFIER, et ça vaut la peine parce que le
  # défaut de Bitwarden est PBKDF2 : tout compte créé ici arrive en PBKDF2 et y
  # reste tant que personne ne va le changer à la main. Constaté le 15 août 2026
  # sur le compte de ce coffre, plusieurs heures après sa création.
  #
  # CE QUE ÇA PROTÈGE. PBKDF2 ne consomme presque pas de mémoire, donc une carte
  # graphique en essaie des milliers en parallèle ; Argon2id réclame de la
  # mémoire à chaque tentative et effondre ce parallélisme. Sur cette machine-ci
  # l'écart est décisif : le disque n'étant pas chiffré, un vol du serveur livre
  # la base, et le KDF est alors LA dernière barrière devant les mots de passe.
  #
  # Comme la sonde ACME du module proxy, elle ne notifie rien elle-même : elle
  # SORT EN ERREUR (cf. myLib.server.mkProbe).
  kdfCheckText = ''
    db=${dataDir}/db.sqlite3

    if [ ! -r "$db" ]; then
      echo "base introuvable ou illisible : $db" >&2
      exit 1
    fi

    # `-readonly` : aucune écriture possible, même par accident, sur la base
    # vivante d'un service qui tourne.
    #
    # `coalesce` sur la memoire : elle vaut NULL pour un compte PBKDF2, et en
    # SQL `NULL < 64` ne vaut pas VRAI mais NULL — la comparaison seule
    # laisserait donc passer exactement les comptes qu'on cherche.
    faibles=$(sqlite3 -readonly "$db" \
      "select email from users
       where client_kdf_type <> 1
          or coalesce(client_kdf_iter, 0) < ${toString cfg.kdfCheck.minIterations}
          or coalesce(client_kdf_memory, 0) < ${toString cfg.kdfCheck.minMemory};")

    if [ -n "$faibles" ]; then
      echo "comptes sous le plancher Argon2id (${toString cfg.kdfCheck.minMemory} Mio, ${toString cfg.kdfCheck.minIterations} iterations) :" >&2
      echo "$faibles" >&2
      echo "corriger depuis le coffre web : Parametres > Securite > Cles de chiffrement." >&2
      exit 1
    fi

    echo "tous les comptes sont en Argon2id au-dessus du plancher"
  '';

  # Le fichier d'environnement n'existe que s'il y a quelque chose de secret à y
  # mettre. Sans SMTP ni panneau d'administration, le service tourne sans aucun
  # secret — donc sans rien à ajouter au dépôt privé pour démarrer.
  needsEnvFile = mail.enable || cfg.admin.tokenKey != null;
in
{
  options.systemSettings.vaultwarden = {
    enable = lib.mkEnableOption "coffre-fort de mots de passe Vaultwarden";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "vault.vpn.exemple.fr";
      description = ''
        Nom servi, et il vaut mieux le choisir sous `vpn.` : c'est la convention
        du parc pour un nom qui ne résout QUE vers l'adresse de think dans le
        tunnel (cf. `nextcloud.extraHostNames` dans profiles/server/nextcloud.nix).

        Il demande UN ENREGISTREMENT A PUBLIC vers l'adresse du serveur dans le
        tunnel — 10.8.0.1 — en « DNS only » chez Cloudflare, à poser à la main
        comme celui de `cloud.vpn.`. Cette adresse n'étant pas routable depuis
        internet, le nom ne fonctionne que le tunnel monté, ce qui est
        exactement la sémantique voulue.

        Pourquoi pas un nom en `.lan.`, que dnsmasq résout sans rien publier :
        les peers WireGuard ne reçoivent AUCUN résolveur (`vpn.wireguard.dns`
        est vide, cf. le profil), donc ils ne connaissent pas la zone interne.
        Un nom en `.lan.` ne résoudrait que depuis think elle-même.

        Le certificat, lui, ne pose aucune question : la validation ACME est en
        DNS-01, elle n'a pas besoin que le nom soit joignable.
      '';
    };

    allowedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        lib.optional wireguard.enable wireguard.subnet
        ++ lib.optional (wireguard.selfSource != null) wireguard.selfSource;
      defaultText = lib.literalExpression "[ vpn.wireguard.subnet vpn.wireguard.selfSource ]";
      example = [ "10.8.0.0/24" ];
      description = ''
        Sources autorisées par nginx, en notation `allow` — tout le reste reçoit
        un 403 avant même d'atteindre Vaultwarden.

        LA PLAGE DU TUNNEL, et c'est la seule qui donne un accès normal. Dans le
        tunnel, `AllowedIPs` en /32 épingle l'adresse source de chaque peer à sa
        clé publique : un appareil ne peut pas se présenter sous celle d'un
        autre, et un appareil non appairé n'entre pas du tout. Le LAN n'y est
        PAS, pour la raison détaillée dans les règles d'Authelia de Nextcloud :
        n'importe quoi de branché sur le WiFi prend une adresse du /24.

        L'ADRESSE DU HOST EN /32 (`vpn.wireguard.selfSource`), pour la sonde
        de surveillance et pour elle seule. Elle vise le nom en `vpn.`, donc
        10.8.0.1, mais le masquerade
        posé par `networking.nat` pour le tunnel (cf.
        modules/system/server/vpn/wireguard) réécrit la source de tout paquet
        émis depuis 10.8.0.0/24 — y compris ceux que think s'envoie à
        elle-même. nginx voit donc 192.168.1.32 et la première ligne ne
        s'applique pas. Même contournement que la règle `status.php` d'Authelia,
        et même innocuité : pour se présenter sous cette adresse, il faut la
        détenir.

        LISTE VIDE = service injoignable. Une assertion le refuse plutôt que de
        laisser un 403 universel se découvrir depuis un téléphone.
      '';
    };

    signups.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Autorise la création de compte depuis la page d'accueil.

        FAUX PAR DÉFAUT, mais il faut bien créer le PREMIER compte : passer
        cette option à `true`, rebuild, créer le compte depuis un appareil du
        VPN, puis la repasser à `false` et rebuild. La fenêtre reste ouverte le
        temps de deux rebuilds, sur un service que seuls les appareils appairés
        atteignent.

        Les comptes SUIVANTS n'en ont pas besoin : une organisation Vaultwarden
        invite par courriel (`INVITATIONS_ALLOWED`, actif), ce qui est le chemin
        à préférer pour la famille — l'invitation nomme le destinataire au lieu
        d'ouvrir la porte à tout le monde.
      '';
    };

    signups.domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "exemple.fr" ];
      description = ''
        Domaines de courriel acceptés à l'inscription. Liste vide : aucune
        restriction, ce qui est sans conséquence tant que `signups.enable` est
        faux.

        Filet complémentaire et non substitut : il n'empêche pas quelqu'un qui
        atteint la page d'utiliser une adresse du bon domaine. Ce qui protège
        est de garder l'inscription fermée.
      '';
    };

    admin.tokenKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "vaultwarden/admin_token";
      description = ''
        Clé sops du jeton du panneau `/admin`. `null` (défaut) : le panneau est
        DÉSACTIVÉ — Vaultwarden refuse d'y répondre sans jeton, ce n'est pas
        seulement une page cachée.

        Fermé par défaut parce qu'il n'apporte rien au quotidien : il sert à
        inviter des comptes et à lire des réglages, ce que l'organisation et ce
        module font déjà. En face, il donne la main sur l'instance à qui détient
        une seule chaîne de caractères, sans second facteur.

        La valeur du secret est de préférence un HACHAGE argon2 —
        `vaultwarden hash` le produit — et non le jeton en clair : Vaultwarden
        accepte encore le clair mais le signale à chaque démarrage, et un jeton
        en clair volé dans un fichier d'environnement s'utilise tel quel.
      '';
    };

    webVault = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sert l'interface web du coffre depuis ce serveur.

        LE SEUL ENDROIT OÙ LE CHIFFREMENT DE BOUT EN BOUT PEUT TOMBER, et c'est
        pour ça que cette option existe plutôt que d'être laissée au défaut. Le
        coffre web est du JavaScript servi par CETTE machine : s'en servir, c'est
        exécuter du code venu du serveur et lui confier son mot de passe maître.
        Un serveur compromis pourrait donc le voler, alors qu'il ne peut rien
        contre l'extension ou l'application mobile, dont le code vient d'un
        magasin signé et ne dépend pas de lui.

        VRAI malgré ça, et c'est un choix assumé : c'est le seul accès de secours
        quand un client casse. Le 15 août 2026, extension et mobile affichaient
        un coffre vide pendant des heures — sans l'interface web, il n'y avait
        plus aucun accès aux mots de passe, ni pour s'en servir ni pour
        diagnostiquer.

        L'atténuation ne coûte rien et ne se configure pas : ne l'employer que
        pour du dépannage, jamais au quotidien. La surface n'existe que pendant
        qu'on s'en sert.
      '';
    };

    requireDeviceEmail = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Exige un code reçu par courriel à la première connexion depuis un
        appareil inconnu.

        FAUX PAR DÉFAUT, après arbitrage explicite. Le gain serait un troisième
        facteur : un mot de passe maître ET un TOTP volés ne suffiraient plus.
        Mais la documentation amont est catégorique — « If sending the email
        fails the login attempt will fail!! » — donc activer ceci fait dépendre
        la connexion depuis un appareil neuf du bon fonctionnement du relais
        SMTP, c'est-à-dire d'un tiers.

        Le scénario qui tranche : téléphone perdu, on veut se connecter depuis
        un appareil de remplacement, et Resend est en panne ou son jeton a
        expiré. On est alors enfermé dehors, et la seule sortie est un accès SSH
        à cette machine pour basculer cette option et rebuild.

        Face à ça, le gain est mince ICI : le compte porte déjà un TOTP, et
        `allowedNetworks` limite déjà l'accès à une poignée d'appareils du
        tunnel. À reconsidérer le jour où ce coffre serait publié.
      '';
    };

    orgCreation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Autorise la création d'organisations, le mécanisme de partage entre
        comptes.

        FERMÉ PAR DÉFAUT au titre de « ce qui ne sert pas reste fermé ». Le gain
        de sécurité est honnêtement marginal sur une instance à un seul compte :
        qui pourrait créer une organisation détient déjà une session, donc le
        coffre.

        À OUVRIR le jour où la famille arrive : l'invitation par courriel part
        d'une organisation, et c'est le chemin à préférer pour créer les comptes
        suivants — il nomme le destinataire, là où rouvrir `signups` ouvre à
        tout le monde. Basculer, rebuild, inviter, refermer.
      '';
    };

    trashRetentionDays = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 30;
      description = ''
        Jours avant purge définitive d'une entrée mise à la corbeille. `null`
        garde le comportement amont, qui est de ne JAMAIS purger.

        Trente jours : assez pour rattraper une suppression qu'on regrette,
        assez court pour qu'un identifiant révoqué ne traîne pas indéfiniment
        dans une base qu'on cherche par ailleurs à garder maigre.
      '';
    };

    kdfCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Sonde quotidienne qui vérifie que TOUS les comptes dérivent leur clé
          en Argon2id, au-dessus d'un plancher.

          Vraie par défaut, contrairement à l'usage de ce dépôt, pour la même
          raison que la sonde d'expiration des certificats : elle contrôle un
          ÉTAT que rien d'autre ne signale. Le défaut de Bitwarden est PBKDF2,
          donc un compte créé ici arrive faible et le reste en silence — c'est
          arrivé au premier compte de ce coffre, et rien ne l'aurait dit.

          Elle prendra tout son sens le jour où la famille aura des comptes :
          chacun choisira son mot de passe et personne n'ira vérifier son
          algorithme de dérivation.
        '';
      };

      minMemory = lib.mkOption {
        type = lib.types.ints.positive;
        default = 64;
        description = ''
          Mémoire minimale acceptée, en mébioctets. Soixante-quatre est le
          défaut de Bitwarden et ce qui rend l'attaque par carte graphique
          coûteuse ; en dessous, l'avantage d'Argon2id sur PBKDF2 fond.
        '';
      };

      minIterations = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Nombre de passes minimal accepté. Trois est le défaut de Bitwarden.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Fréquence de la sonde, au format `OnCalendar` de systemd.";
      };
    };

    backupDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/backup/vaultwarden";
      description = ''
        Répertoire où le module amont dépose chaque nuit une copie cohérente de
        la base (`sqlite3 .backup`), des clés RSA et des pièces jointes. `null`
        coupe la sauvegarde.

        ACTIVÉ PAR DÉFAUT, contrairement à l'usage de ce dépôt, parce que la
        donnée qui vit ici ne se reconstruit pas : un fichier Nextcloud perdu se
        retrouve souvent ailleurs, un coffre perdu ne se retrouve nulle part.

        CE QUE ÇA NE COUVRE PAS, et il faut le dire : la copie est sur LE MÊME
        DISQUE, écrasée chaque nuit. Elle protège d'une base corrompue et d'une
        suppression maladroite, pas d'une panne de disque ni d'une erreur
        remarquée trois jours plus tard. Tant qu'il n'y a pas de sauvegarde
        hors machine sur ce parc, l'export chiffré depuis un client Bitwarden
        reste le seul filet contre la perte du disque — à faire de temps en
        temps, à ranger ailleurs.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.hostName != "";
            message = "systemSettings.vaultwarden : hostName est requis, c'est le nom du vhost qui sert le coffre.";
          }
          {
            assertion = config.systemSettings.proxy.enable;
            message = "systemSettings.vaultwarden exige systemSettings.proxy.enable : c'est lui qui porte nginx et le certificat du vhost.";
          }
          {
            # Une liste vide produirait un `deny all` seul : le service démarre, le
            # certificat s'émet, et TOUT LE MONDE reçoit 403 — y compris le
            # téléphone depuis lequel on essaie de comprendre pourquoi.
            assertion = cfg.allowedNetworks != [ ];
            message = "systemSettings.vaultwarden : allowedNetworks est vide, donc nginx refuserait toute source. Renseigne au moins la plage du tunnel WireGuard.";
          }
          {
            assertion = cfg.admin.tokenKey == null || cfg.admin.tokenKey != "";
            message = "systemSettings.vaultwarden : admin.tokenKey doit nommer une clé du dépôt de secrets, ou valoir null pour désactiver le panneau.";
          }
        ];

        warnings = lib.optional cfg.signups.enable ''
          systemSettings.vaultwarden : l'inscription est OUVERTE sur ${cfg.hostName}.
          C'est la position à ne garder que le temps de créer les premiers comptes —
          repasse signups.enable à false ensuite, les suivants s'invitent par courriel.
        '';

        services.vaultwarden = {
          enable = true;

          # SQLite, le défaut, et il n'y a pas de raison d'en changer ici : un
          # coffre familial fait quelques milliers de lignes, la base tient dans le
          # cache du système de fichiers, et c'est le seul backend que la sauvegarde
          # du module amont sait traiter.
          dbBackend = "sqlite";

          inherit (cfg) backupDir;

          # Devient `DOMAIN=https://<nom>`. Ce n'est PAS cosmétique : Vaultwarden
          # s'en sert pour les liens des courriels d'invitation, et surtout comme
          # identifiant de partie vérifiante WebAuthn — une clé de sécurité
          # enrôlée sous un nom ne fonctionne pas sous un autre.
          domain = cfg.hostName;

          environmentFile = lib.optional needsEnvFile config.sops.templates."vaultwarden.env".path;

          config = {
            # BOUCLE LOCALE UNIQUEMENT. Le défaut du module amont est `::1`, ce qui
            # marcherait aussi, mais nginx proxifie vers 127.0.0.1 et l'IPv6 est
            # coupée sur ce parc (cf. modules/system/network).
            ROCKET_ADDRESS = "127.0.0.1";
            ROCKET_PORT = port;

            # Notifications poussées aux clients par websocket : sans ça, un mot de
            # passe changé sur le téléphone n'apparaît sur le navigateur qu'à la
            # prochaine synchronisation manuelle. Le vhost route les deux chemins de
            # hub plus bas.
            ENABLE_WEBSOCKET = true;

            SIGNUPS_ALLOWED = cfg.signups.enable;
            SIGNUPS_DOMAINS_WHITELIST = lib.concatStringsSep "," cfg.signups.domains;

            # Pas de vérification de courriel à l'inscription, alors que le relais
            # SMTP existe. La création de compte est une fenêtre de quelques minutes
            # sur un service que seuls les appareils appairés atteignent : y ajouter
            # une dépendance au bon fonctionnement du relais, c'est risquer un compte
            # créé mais inutilisable, sans autre moyen de le débloquer que de
            # rouvrir un panneau d'administration qu'on garde fermé.
            SIGNUPS_VERIFY = false;

            # L'indice de mot de passe maître, affiché à qui connaît l'adresse. Faux
            # est déjà le défaut amont ; on l'écrit parce que c'est le genre de
            # défaut qu'une version peut changer, et qu'ici il divulguerait un
            # indice sur LE mot de passe qui ouvre tout.
            SHOW_PASSWORD_HINT = false;

            WEB_VAULT_ENABLED = cfg.webVault;
            REQUIRE_DEVICE_EMAIL = cfg.requireDeviceEmail;

            # `all` et `none` sont les deux valeurs spéciales de ce réglage, le
            # défaut amont étant la chaîne vide, synonyme de `all`.
            ORG_CREATION_USERS = if cfg.orgCreation then "all" else "none";

            # `null` est retiré par le module amont, qui n'émet pas la variable —
            # on retombe alors sur le défaut, qui est de ne jamais purger.
            TRASH_AUTO_DELETE_DAYS = cfg.trashRetentionDays;

            # SECOND FACTEUR REDEMANDÉ À CHAQUE CONNEXION. Sans ça, un cookie
            # dispense du TOTP pendant trente jours sur l'appareil où l'on a coché
            # « se souvenir » : le second facteur cesse d'exister là où il compte
            # le plus, c'est-à-dire sur une machine qu'on peut se faire voler.
            DISABLE_2FA_REMEMBER = true;

            # Les codes TOTP des trente secondes précédentes et suivantes cessent
            # d'être acceptés. Ferme le rejeu d'un code aperçu par-dessus l'épaule
            # ou intercepté, au prix d'une exigence sur l'horloge — celle de think
            # est synchronisée et surveillée, celle d'un téléphone l'est aussi.
            AUTHENTICATOR_DISABLE_TIME_DRIFT = true;

            # PLUS AUCUNE ICÔNE TÉLÉCHARGÉE. Le service interne allait chercher la
            # favicone de chaque site présent dans le coffre : ce serveur annonçait
            # donc à des tiers, requête après requête, LA LISTE DES SITES où l'on a
            # un compte. C'est la seule fuite d'information que ce montage produisait
            # vers l'extérieur, et elle ne coûte que des logos dans l'interface.
            DISABLE_ICON_DOWNLOAD = true;

            # Le client HTTP interne refuse les adresses non publiques. Sans lui,
            # une URI rangée dans une entrée pouvait faire frapper le serveur sur
            # 127.0.0.1 ou sur le LAN — une requête falsifiée côté serveur, depuis
            # une machine qui est justement au bon endroit du réseau pour que ça
            # compte. Le défaut amont ne le pose PAS, vérifié dans le modèle de
            # configuration de la 1.37.1.
            HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS = true;

            # Deux mécanismes qu'on n'emploie pas et qui donnent chacun un chemin
            # vers le contenu du coffre ou vers le compte : l'accès d'urgence, qui
            # confie ses clés à un autre compte après un délai, et le changement
            # d'adresse, étape classique d'une prise de contrôle. Fermés.
            EMERGENCY_ACCESS_ALLOWED = false;
            EMAIL_CHANGE_ALLOWED = false;

            # LES LIMITES DE DÉBIT RESTENT À LEUR DÉFAUT (une moyenne d'une requête
            # par minute et par adresse, avec une rafale de dix), et c'est délibéré.
            # Les resserrer protégerait d'un devinage en ligne que trois autres
            # barrières rendent déjà sans objet — accès restreint à quelques
            # appareils du tunnel, TOTP, mot de passe maître à haute entropie —
            # pendant qu'une valeur trop basse casserait le renouvellement de jeton
            # de plusieurs clients derrière la même adresse. On n'échange pas de la
            # fiabilité contre une sécurité qu'on a déjà.
          }
          // lib.optionalAttrs mail.enable {
            SMTP_HOST = mail.host;
            SMTP_PORT = mail.port;
            # `force_tls` pour du TLS implicite (465), `starttls` pour une
            # négociation (587). Même aiguillage que le module Nextcloud, dans le
            # vocabulaire de Vaultwarden.
            SMTP_SECURITY = if mail.implicitTls then "force_tls" else "starttls";
            SMTP_USERNAME = mail.user;
            SMTP_FROM = mail.from;
            SMTP_FROM_NAME = "Coffre-fort";
            # Le mot de passe n'est PAS ici : cet attribut finit en clair dans le
            # store. Il arrive par le gabarit sops juste en dessous.
          };
        };

        # Gabarit substitué à l'activation, jamais écrit dans le store. Appartient à
        # `vaultwarden`, seul à devoir le lire — d'où l'absence de ce service du
        # groupe `smtp`, que Nextcloud n'emprunte pas non plus.
        #
        # FORMAT : systemd lit ce fichier comme un `EnvironmentFile`, donc une paire
        # `CLÉ=valeur` par ligne, sans guillemets. Un mot de passe contenant une
        # apostrophe, un guillemet ou une contre-oblique demanderait un échappement —
        # aucun relais n'en produit, mais c'est la chose à regarder en premier si
        # l'authentification SMTP échoue avec un mot de passe pourtant juste.
        sops.templates."vaultwarden.env" = lib.mkIf needsEnvFile {
          owner = "vaultwarden";
          mode = "0400";
          content =
            lib.optionalString mail.enable ''
              SMTP_PASSWORD=${config.sops.placeholder.${mail.passwordKey}}
            ''
            + lib.optionalString (cfg.admin.tokenKey != null) ''
              ADMIN_TOKEN=${config.sops.placeholder.${cfg.admin.tokenKey}}
            '';
        };

        sops.secrets = lib.mkIf (cfg.admin.tokenKey != null) {
          ${cfg.admin.tokenKey} = { };
        };

        # ------------------------------------------------------------- publication

        services.nginx.virtualHosts.${cfg.hostName} = myLib.server.mkTlsVhost {
          # LE FILTRAGE PAR SOURCE, posé au niveau `server` : les locations en
          # héritent, et une location ajoutée plus tard ne peut pas l'oublier.
          #
          # `$remote_addr` implicitement, jamais un en-tête — `allow` ne regarde que
          # l'adresse de la connexion TCP, qu'un client ne peut pas falsifier sans
          # établir la poignée de main depuis cette adresse. C'est la même règle que
          # pour les `networks` d'Authelia : une décision d'accès ne s'appuie sur
          # aucun en-tête, fût-il réputé fiable.
          extraConfig = ''
            ${myLib.server.nginxAllowOnly cfg.allowedNetworks}

            # Pièces jointes et « Sends ». Le défaut de nginx est un mégaoctet, ce
            # qui refuse à peu près tout fichier avec un 413 que le client Bitwarden
            # rapporte comme une erreur réseau sans plus de détail.
            client_max_body_size 128M;
          '';

          locations = {
            "/".proxyPass = proxyPass;

            # LES DEUX HUBS DE NOTIFICATION, en correspondance EXACTE (`=`) : ce
            # sont les seuls chemins qui basculent en websocket, et le reste doit
            # rester en HTTP ordinaire. Sans eux, le coffre fonctionne mais les
            # clients ne se mettent à jour qu'en synchronisant à la main.
            #
            # JOURNALISATION COUPÉE SUR CES DEUX-LÀ, et uniquement sur eux. Les
            # clients y présentent leur jeton DANS L'URL :
            #
            #   GET /notifications/hub?access_token=eyJ0eXAiOiJKV1Qi…
            #
            # et le format de journal de nginx écrit la ligne de requête entière.
            # Chaque connexion websocket déposait donc un jeton valide en clair dans
            # `/var/log/nginx/access.log`, fichier qui survit aux redémarrages et
            # part dans toute copie du système de fichiers. Ce jeton ne déchiffre
            # rien — la clé ne quitte jamais le client — mais il donne l'API : de
            # quoi aspirer les blocs chiffrés, donc emporter la matière d'une
            # attaque hors ligne, et de quoi SUPPRIMER des entrées.
            #
            # Ce qu'on perd : la trace des connexions websocket côté nginx. Le
            # journal de Vaultwarden les consigne toujours, lui.
            "= /notifications/hub" = {
              inherit proxyPass;
              proxyWebsockets = true;
              extraConfig = "access_log off;";
            };

            "= /notifications/anonymous-hub" = {
              inherit proxyPass;
              proxyWebsockets = true;
              extraConfig = "access_log off;";
            };
          }
          # PANNEAU D'ADMINISTRATION FERMÉ UNE SECONDE FOIS, au niveau du proxy,
          # quand aucun jeton n'est configuré.
          #
          # Vaultwarden le refuse déjà sans `ADMIN_TOKEN` : ceci ne corrige donc rien
          # aujourd'hui, ça verrouille DEMAIN. Le jour où un jeton serait posé pour
          # dépanner puis oublié, ou remis par un défaut amont qui change, la porte
          # se rouvrirait sans que personne le remarque — et c'est une porte qui
          # donne l'instance entière à qui détient une chaîne de caractères, sans
          # second facteur. Deux verrous qui tombent ensemble valent mieux qu'un.
          #
          # `^~` et non `=` : le préfixe couvre aussi `/admin/…`, et cette forme
          # l'emporte sur les correspondances par expression régulière.
          #
          # 404 plutôt que 403 : ne pas confirmer que l'endroit existe.
          // lib.optionalAttrs (cfg.admin.tokenKey == null) {
            "^~ /admin".extraConfig = "return 404;";
          };
        };

        # AUCUNE entrée dans `cloudflared.ingress`, et c'est le cœur du montage :
        # sans route, le nom public ne mène nulle part depuis internet. Cf. l'en-tête
        # de ce module pour ce qu'il faudrait ajouter — Authelia compris — le jour
        # où l'on voudrait le publier.

        # ------------------------------------------------------------ surveillance

        # `/alive` répond un horodatage JSON sans authentification : c'est le point
        # de santé prévu par Vaultwarden, et il traverse Rocket ET la base, donc il
        # tombe si le service est vivant mais sa base illisible.
        #
        # La sonde part de think, dont l'adresse est dans `allowedNetworks` par
        # défaut (cf. la description de l'option pour le pourquoi du masquerade).
        systemSettings.proxy.sites.${cfg.hostName}.probes.vaultwarden.path = "/alive";

        systemSettings.notify.discord.units = [
          "vaultwarden"
        ]
        # La sauvegarde aussi, et elle en a plus besoin que le service : personne
        # ne remarque une copie qui ne se fait plus, jusqu'au jour où l'on en a
        # besoin.
        ++ lib.optional (cfg.backupDir != null) "backup-vaultwarden";

        # MASQUE DE CRÉATION DE LA SAUVEGARDE, que le module amont ne pose pas.
        #
        # `sqlite3 .backup` crée son fichier avec le masque de l'unité, soit 0022
        # par défaut : la base sauvegardée se retrouvait en 0644, LISIBLE PAR TOUT
        # LE MONDE, pendant que la base vivante est en 0700 et que la clé RSA
        # copiée à côté garde son 0600 — `cp` préserve les modes de la source,
        # `.backup` non. Constaté sur la copie du 15 août 2026.
        #
        # Ce que ça valait : seul le mode du répertoire (0770) fermait l'accès,
        # donc une barrière unique, et une barrière qui ne voyage pas — un
        # `tar` ou un `rsync` de ce répertoire vers un autre support emporterait
        # un fichier de coffre lisible par n'importe quel compte de la machine de
        # destination.
        #
        # ATTENTION, ce réglage ne corrige que les copies À VENIR : `.backup`
        # réutilise le fichier s'il existe déjà, et garde donc son mode. Un
        # `chmod 0600` sur la copie en place est nécessaire une fois.
        systemd.services.backup-vaultwarden.serviceConfig.UMask = lib.mkIf (cfg.backupDir != null) "0077";

      }

      (lib.mkIf cfg.kdfCheck.enable (
        myLib.server.mkProbe pkgs-stable {
          name = "vaultwarden-kdf-check";
          description = "Vérifie que les comptes du coffre dérivent en Argon2id";
          timerDescription = "Sonde quotidienne du KDF des comptes du coffre";
          inherit (cfg.kdfCheck) interval;
          runtimeInputs = [ pkgs-stable.sqlite ];
          text = kdfCheckText;

          # `after` et non `requires` : la sonde lit un FICHIER, pas le service.
          # Elle doit donc pouvoir tourner et rendre son verdict même si
          # Vaultwarden est arrêté — un service à terre est déjà signalé par
          # ailleurs, et ce n'est pas une raison pour perdre le contrôle du KDF.
          after = [ "vaultwarden.service" ];

          serviceConfig = {
            # L'UTILISATEUR DU SERVICE, et pas root : la base lui appartient,
            # donc c'est la moindre autorité qui permette de la lire. Le reste
            # du durcissement suit ce que le module amont applique au service
            # lui-même, avec en plus l'interdiction de toucher au réseau — cette
            # sonde n'a rien à y faire.
            User = "vaultwarden";
            Group = "vaultwarden";

            # RÉPERTOIRE ACCESSIBLE EN ÉCRITURE, alors qu'on ne fait que lire —
            # et c'est OBLIGATOIRE, pas un relâchement.
            #
            # La base tourne en mode WAL (`enable_db_wal`, vrai par défaut chez
            # Vaultwarden). Un LECTEUR SQLite y a besoin d'écrire le fichier de
            # verrouillage partagé `-shm` : c'est par lui que passe la
            # coordination entre lecteurs et écrivain. Avec le répertoire en
            # lecture seule, la sonde échoue sur « attempt to write a readonly
            # database » — vérifié en reproduisant le cas, la requête sortait en
            # code 8 sans jamais lire une ligne.
            #
            # Le coût aurait été pire qu'une sonde inutile : elle aurait échoué
            # CHAQUE JOUR, donc alerté chaque jour, et une alerte qui crie
            # toujours finit par n'être plus lue — y compris le jour où elle a
            # raison.
            #
            # La lecture seule est donc obtenue par SQLite (`-readonly`) et non
            # par le système de fichiers : une écriture reste refusée en code 8,
            # vérifié aussi. `ProtectSystem=strict` garde tout le reste du
            # système hors de portée.
            ReadWritePaths = [ dataDir ];

            NoNewPrivileges = true;
            PrivateNetwork = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictNamespaces = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
            ];
            CapabilityBoundingSet = [ "" ];
            UMask = "0077";
          };
        }
      ))
    ]
  );
}
