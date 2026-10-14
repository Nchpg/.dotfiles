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
#
# Découpé par sujet : options.nix (les options), nginx.nix (le vhost et le
# portail), occ-units.nix (les réglages appliqués par `occ`). Ce fichier porte
# l'instance elle-même, sa publication et sa politique d'accès.
let
  cfg = config.systemSettings.nextcloud;
  authelia = config.systemSettings.authelia;
  mail = config.systemSettings.mail;
  wireguard = config.systemSettings.vpn.wireguard;
  monitoring = config.systemSettings.monitoring;

  # Nom du chemin RÉSERVÉ, celui que visent les clients de synchronisation et
  # les sondes (cf. `extraHostNames`).
  internalHost = if cfg.extraHostNames != [ ] then lib.head cfg.extraHostNames else null;

  # Paquet Nextcloud, patché quand `canonicalLinkWebUi` est vrai pour figer
  # l'hôte du lien de partage DANS le bundle web. Cf. l'option pour le pourquoi
  # et le coût. Le patch est un remplacement ciblé sur le seul appel qui
  # construit ce lien, doublé d'une garde qui fait échouer le build si le motif
  # n'est plus trouvé — le silence n'est pas une option pour du code amont
  # minifié.
  nextcloudPackage =
    if cfg.publicSharing.enable && cfg.publicSharing.canonicalLinkWebUi then
      myLib.mkNextcloudShareLinkPatch {
        package = pkgs-stable.nextcloud33;
        inherit (pkgs-stable) perl;
        host = cfg.hostName;
      }
    else
      pkgs-stable.nextcloud33;
in
{
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

    # POLITIQUE D'ACCÈS D'AUTHELIA pour ce service, émise ICI plutôt que
    # recopiée dans le profil : elle découle de `hostName`, `extraHostNames` et
    # de la plage du tunnel, et un nom changé d'un côté ne doit pas laisser une
    # règle orpheline de l'autre.
    #
    # L'ORDRE COMPTE : la première règle qui correspond gagne, et la règle
    # sans `networks` en dernière position sert de filet. Toute origine non
    # listée tombe donc sur `two_factor`, jamais sur un contournement —
    # l'erreur possible est de refuser à tort, pas d'ouvrir.
    #
    # L'adresse évaluée est celle que nginx force depuis `$remote_addr` (cf.
    # modules/system/server/authelia) : l'adresse TCP réelle, qu'un client ne
    # peut pas falsifier par un en-tête. Vérifié en conditions réelles, un
    # X-Forwarded-For fabriqué et envoyé à travers le tunnel ne contourne
    # rien.
    #
    # EN TÊTE, le contournement du portail sur les seuls chemins de partage
    # public (cf. `publicSharing.enable`).
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
    # `mkBefore` pour TOUTE la liste, contournement des partages en tête : ces
    # règles passent avant celles d'autres services (Grafana dans le profil),
    # et la règle `two_factor` sans `networks` qui la clôt n'attrape que ce
    # service-ci.
    systemSettings.authelia.rules = lib.mkBefore (
      lib.optionals authelia.enable (
        lib.optional cfg.publicSharing.enable {
          domain = cfg.hostName;
          policy = "bypass";
          resources = cfg.publicSharing.autheliaResources;
        }
        ++ lib.optionals wireguard.enable (
          map
            (host: {
              domain = host;
              policy = "bypass";
              networks = [ wireguard.subnet ];
            })
            (
              # Atteint depuis le VPN : pas de portail.
              #
              # `192.168.1.0/24` a été RETIRÉ de cette liste, et c'est la seule
              # différence de fond entre les deux plages. Dans le tunnel, `AllowedIPs`
              # en /32 épingle l'adresse source de chaque peer à sa clé publique : un
              # appareil ne peut pas se présenter sous celle d'un autre, et un
              # appareil non appairé n'entre pas du tout. Sur le LAN, rien de tel —
              # n'importe quoi de branché sur le WiFi prend une adresse du /24, donc
              # sautait le second facteur en forçant simplement la résolution vers
              # 192.168.1.32 (DNS statique, `curl --resolve`, l'IP avec le bon
              # `Host`). Le contournement ne reposait sur rien d'autre que le fait
              # que personne n'essaie.
              #
              # CE QUE ÇA NE COÛTE PAS : les clients de synchronisation visent
              # `cloud.vpn.…` (cf. `nextcloud.extraHostNames`), qui passe par la
              # règle suivante — le tunnel de gram et du téléphone est monté en
              # permanence. Et les navigateurs de la maison tombaient DÉJÀ sur le
              # portail : la box ne distribue pas dnsmasq comme résolveur, donc
              # `cloud.` part vers l'edge Cloudflare et revient par le tunnel, où
              # nginx voit 127.0.0.1. Vérifié sur le moteur de règles d'Authelia.
              #
              # Bénéfice à retardement : le jour où le DHCP de la box pointe vers
              # dnsmasq — ce que modules/system/server/dns envisage explicitement —
              # tout le LAN se serait mis à contourner le portail sans un message.
              # La posture ne dépend plus d'un réglage hors dépôt.
              #
              # Si un appareil de la maison doit un jour se passer du portail, la
              # réponse est de l'appairer au VPN, pas de rouvrir le /24.
              [ cfg.hostName ]
              # Nom du chemin réservé, celui que visent les clients de
              # synchronisation. Il ne résout que vers l'adresse de think dans le
              # tunnel, donc l'atteindre suppose déjà une clé WireGuard déclarée.
              #
              # Les `networks` ne sont pas décoratives pour autant : sans elles la
              # règle serait un contournement INCONDITIONNEL, dont l'innocuité ne
              # tiendrait qu'à un enregistrement DNS et au `httpHostHeader` forcé
              # côté cloudflared — une ligne de configuration ailleurs, et le trou
              # s'ouvrirait sans un message.
              ++ cfg.extraHostNames
            )
        )
        ++ lib.optionals (internalHost != null && wireguard.selfSource != null) (
          # La MÊME chose, pour think elle-même, et uniquement pour la page
          # d'état. Elle existe pour la sonde de surveillance, qui vérifie que
          # Nextcloud répond vraiment — PHP et la base interrogés — et pas
          # seulement que nginx sert quelque chose.
          #
          # POURQUOI L'ADRESSE DU LAN et non celle du tunnel, alors que la sonde
          # vise bien `cloud.vpn.` donc `10.8.0.1` : le masquerade posé par
          # `networking.nat` pour le tunnel (cf. modules/system/server/vpn/wireguard)
          # correspond à toute source dans `10.8.0.0/24` sans exclure la moindre
          # interface. Un paquet que think émet vers sa propre adresse de tunnel
          # traverse POSTROUTING et ressort en 192.168.1.32. La règle au-dessus
          # ne peut donc PAS s'appliquer, et le chemin du VPN n'est pas
          # empruntable depuis la machine qui le sert.
          #
          # CE QUE ÇA N'OUVRE PAS. `resources` restreint à la seule page d'état,
          # qui ne divulgue que la version de Nextcloud. Et pour se présenter
          # sous cette adresse, il faut la détenir : une source falsifiée
          # n'établit pas de poignée de main TCP. En pratique, seule cette
          # machine correspond.
          #
          # Si le masquerade change un jour et cesse de réécrire ce trafic, la
          # règle précédente reprend la main toute seule — la sonde ne casse pas.
          lib.optional monitoring.enable {
            domain = internalHost;
            policy = "bypass";
            networks = [ wireguard.selfSource ];
            resources = [ "^/status\\.php$" ];
          }
          # MÊME MONTAGE que la règle ci-dessus, et pour la même raison : l'appel
          # part de cette machine, donc ressort en 192.168.1.32 après masquerade.
          # Séparée d'elle parce que ce qu'elle ouvre n'est PAS de même nature et
          # devait être pesé à part.
          #
          # Sert l'exporteur Prometheus. L'API `serverinfo` en dit nettement plus
          # que `status.php` : occupation, comptes, partages, versions de PHP et
          # de la base, état des tâches de fond.
          #
          # AUTHELIA N'EST PAS LA SEULE SERRURE, et c'est ce qui rend l'ouverture
          # acceptable : Nextcloud exige sur ce chemin son propre jeton
          # `serverinfo`, que l'exporteur envoie en en-tête `NC-Token`. Retirer
          # le portail ne rend donc pas l'API publique, ça la ramène à
          # l'authentification que l'application fait elle-même. S'y ajoutent la
          # restriction d'origine — qu'une source falsifiée ne franchit pas,
          # faute de poignée de main TCP — et le fait que ce nom n'est ni dans
          # l'ingress du tunnel ni résolvable publiquement, vérifié.
          #
          # CHEMIN EXACT et non préfixe : `serverinfo/` couvrirait tout ce que
          # l'application ajoutera plus tard sous cette racine, y compris des
          # points d'entrée qui n'existent pas encore et que personne ne
          # relirait. Si l'exporteur change d'URL un jour, il tombera en 302 avec
          # du HTML au lieu de JSON — bruyant, donc réparable.
          ++ lib.optional (monitoring.apps.nextcloudTokenKey != null) {
            domain = internalHost;
            policy = "bypass";
            networks = [ wireguard.selfSource ];
            resources = [ "^/ocs/v2\\.php/apps/serverinfo/api/v1/info" ];
          }
        )
        # Nom PUBLIC, servi par le tunnel : deux facteurs, sans exception.
        # Aucune `networks` ici, donc cette règle attrape toute origine que les
        # précédentes n'ont pas reconnue.
        ++ [
          {
            domain = cfg.hostName;
            policy = "two_factor";
          }
        ]
      )
    );

    # PUBLICATION. Le nom public passe par le tunnel (le navigateur, derrière le
    # portail) et répond l'adresse du LAN à la maison (`lanShortcut` suit
    # `public`) : UN SEUL NOM partout, y compris dans les liens de partage,
    # construits d'après l'hôte de la requête en cours. Le nom réservé n'est ni
    # routé ni réécrit : il résout vers l'adresse du serveur dans le tunnel.
    #
    # LES SONDES partent de ce host, où dnsmasq réécrit le nom public vers le
    # LAN : elles tapent nginx en direct et ne traversent PAS le tunnel.
    systemSettings.proxy.sites = {
      ${cfg.hostName} = {
        public = lib.mkDefault true;

        # Le nom PUBLIC doit répondre par une redirection vers le portail. Un
        # 200 signalerait que la protection est tombée, et la sonde le
        # compterait comme un échec.
        probes = lib.optionalAttrs authelia.enable {
          nextcloud-portail.module = "http_authelia";
        };
      };
    }
    // lib.optionalAttrs (internalHost != null) {
      # Le chemin du VPN contourne le portail (règle `bypass` ci-dessus), donc
      # la sonde reçoit la VRAIE réponse de Nextcloud : c'est la seule qui
      # vérifie PHP et la base, pas seulement nginx. Elle suppose le tunnel
      # WireGuard monté, ce qui est le cas — et son absence est en soi une
      # chose qu'on veut savoir.
      ${internalHost}.probes.nextcloud.path = "/status.php";
    };

    services.nextcloud = {
      enable = true;
      # Version majeure épinglée : les migrations de schéma sont irréversibles,
      # un saut de majeure au hasard d'un bump de nixpkgs se découvrirait après
      # coup et sans retour possible.
      package = nextcloudPackage;

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
        mail_smtpsecure = if mail.implicitTls then "ssl" else "tls";
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
  };
}
