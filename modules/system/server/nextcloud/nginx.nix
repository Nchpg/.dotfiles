{
  config,
  lib,
  myLib,
  ...
}:

# nginx devant Nextcloud : le vhost du module amont, complété du TLS, des noms
# supplémentaires, de la limitation des partages publics, de l'hôte canonique
# des liens et du portail.
let
  cfg = config.systemSettings.nextcloud;
  authelia = config.systemSettings.authelia;

  # Location PHP telle que le module amont la construit, une fois toutes les
  # définitions fusionnées — la nôtre comprise. Lue plutôt que recopiée : la
  # location `/s/` ci-dessous en RÉUTILISE le bloc, elle ne peut donc pas
  # diverger le jour où l'amont le modifie. Le seul couplage qui reste est le
  # NOM de la clé.
  phpLocation = config.services.nginx.virtualHosts.${cfg.hostName}.locations."~ \\.php(?:$|/)";
in
{
  config = lib.mkIf cfg.enable {
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
      # `limit_req_status` n'est PAS posé ici : modules/system/server/proxy
      # l'écrit une fois pour tous les vhosts.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.rateLimit.enable) (
        lib.mkAfter ''
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

          # Zone SÉPARÉE pour les vignettes, cf. `previewRate`. Deux seaux
          # distincts et non un seul élargi : l'ouverture d'une galerie ne doit
          # pas consommer le quota qui protège la soumission d'un mot de passe,
          # et inversement.
          #
          # Le motif accepte les DEUX formes, `/apps/…` et `/index.php/apps/…` :
          # la seconde est celle que prend l'URI après la réécriture interne du
          # module amont, et `limit_req` peut l'évaluer sur l'une ou l'autre
          # selon le chemin emprunté. Les couvrir toutes deux évite un trou qui
          # ne dépendrait que de l'ordre des phases nginx.
          map $uri $nextcloud_preview_client {
            volatile;
            default                                              "";
            ~^/(?:index\.php/)?apps/files_sharing/publicpreview  $real_client_ip;
          }

          limit_req_zone $nextcloud_share_client zone=nextcloud_share:10m rate=${cfg.publicSharing.rateLimit.rate};
          limit_req_zone $nextcloud_preview_client zone=nextcloud_preview:10m rate=${cfg.publicSharing.rateLimit.previewRate};
        ''
      ))
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
          # Deuxième seau, plus large, pour les seules vignettes. Deux `limit_req`
          # dans un même contexte s'appliquent CHACUN : une requête doit passer
          # les deux. Une vignette relève du second par sa clé (le premier `map`
          # lui rend une chaîne vide, donc pas de limite côté `nextcloud_share`),
          # et le reste du partage relève du premier.
          limit_req zone=nextcloud_preview burst=${toString cfg.publicSharing.rateLimit.previewBurst} nodelay;
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

      # Page d'erreur NEUTRE sur les chemins de partage, cf. `neutralNotFound`.
      #
      # Pourquoi une location à part plutôt qu'un `error_page` sur celle du PHP :
      # `error_page` se résout dans la location où l'erreur SURVIENT, et celle du
      # PHP sert tout — y compris le WebDAV, dont les 404 sont le quotidien d'un
      # client de synchronisation. Y poser une interception viderait leur corps.
      # On isole donc `/s/`, et rien d'autre ne change de comportement.
      #
      # Le bloc `fastcgi` n'est PAS recopié, il est réutilisé depuis
      # `phpLocation` : une location dupliquée à la main divergerait en silence à
      # la première évolution de l'amont, et la ligne qui s'y perdrait le plus
      # discrètement est le `fastcgi_param HTTP_X_FORWARDED_FOR` — sans lui, le
      # compteur anti-force-brute de Nextcloud sur `publicLinkAuth` verrait
      # 127.0.0.1 pour tout le trafic du tunnel.
      #
      # PRIORITÉ sous celle de la location PHP (500) : les deux sont des
      # expressions régulières, et nginx retient la PREMIÈRE qui correspond dans
      # l'ordre du fichier. Sans ça `/index.php/s/<jeton>` — la forme que prend
      # la requête après la réécriture interne — repartirait dans la location
      # générique et l'interception ne servirait à rien.
      (lib.mkIf (cfg.publicSharing.enable && cfg.publicSharing.neutralNotFound) {
        # Chemins de PARTAGE uniquement, `/s/` et les points publics de
        # files_sharing. Ils ont une propriété que les autres chemins ouverts
        # n'ont pas : ils ne renvoient 404 QUE sur un jeton absent ou expiré,
        # jamais au fil d'un usage normal. Intercepter leur 404 est donc sans
        # dommage collatéral.
        #
        # THEMING EN A ÉTÉ RETIRÉ, et c'est une correction. `apps/theming/img/`
        # est à DOUBLE usage : une route PHP (`img/{app}/{image}`, deux segments)
        # ET un dossier de fichiers statiques — les vignettes de thème de la page
        # Apparence (`accessibility-dark.svg`, `app.svg`, `default-source.svg`,
        # les `.jpg`). Cette location a une priorité inférieure à celle des
        # fichiers statiques, donc elle passait AVANT eux et détournait ces
        # images vers php-fpm, qui n'a pas de route à un seul segment : 404, et
        # les vignettes de la page Apparence cassées. Le mécanisme de la fuite de
        # version sur `/apps/theming/theme/<bidon>.css` reste donc ouvert à un
        # scanner — moindre mal assumé, et bien plus obscur que `/s/`, la seule
        # cible qu'un balayage vise vraiment.
        #
        # Les chemins STATIQUES en général restent dehors pour la même raison :
        # les faire passer par PHP les casse ou les ralentit. `/public.php` aussi
        # (ses 404 sont des corps XML que la page de partage attend, et ils ne
        # divulguent rien).
        locations."~ ^/(?:index\\.php/)?(?:s/|apps/files_sharing/(?:publicpreview|shareinfo))" = {
          priority = phpLocation.priority - 10;
          inherit (phpLocation) fastcgiParams;
          extraConfig =
            phpLocation.extraConfig
            + ''
              error_page 404 = @nextcloud_share_404;
            ''
            # Le 401 du bloc serveur RÉPÉTÉ ici, et ce n'est pas une redondance :
            # nginx n'hérite les `error_page` du niveau supérieur que s'il n'y en
            # a AUCUNE au niveau courant. Poser la 404 ci-dessus annule donc
            # l'aiguillage du 401 vers le portail pour cette location.
            #
            # En pratique `/s/` ne produit pas de 401 — la règle Authelia le
            # contourne, et un partage protégé par mot de passe répond 200 avec
            # son formulaire. C'est justement pour ça qu'il faut l'écrire : la
            # perte ne se verrait pas.
            + lib.optionalString authelia.enable ''
              error_page 401 = @authelia_or_app;
            '';
        };

        locations."@nextcloud_share_404".extraConfig = ''
          internal;
          # Sans ça le point de contrôle serait interrogé une seconde fois pour
          # fabriquer une page d'erreur, la directive du bloc server étant
          # héritée par toutes les locations.
          auth_request off;
          default_type text/html;

          # EN-TÊTES DE SESSION EFFACÉS, et c'est ce qui rend la page vraiment
          # neutre. Sans ça, la réponse porte encore le `Set-Cookie` que PHP a
          # posé avant l'interception — `oc_sessionPassphrase`,
          # `__Host-nc_sameSiteCookielax` — dont les NOMS sont une signature
          # Nextcloud sans équivoque. Cacher la version dans le corps ne servait
          # à rien tant qu'un `Set-Cookie` trahissait le produit à un scanner qui
          # tape `/s/n_importe_quoi`.
          #
          # Sûr sur CE chemin précisément : un jeton invalide (404) n'ouvre
          # aucune session, le cookie n'a donc aucune utilité. On ne l'efface pas
          # sur les réponses 200 d'un vrai partage, qui en ont besoin pour la
          # saisie du mot de passe — d'où l'effacement ICI et pas sur la location
          # qui passe à php-fpm.
          #
          # `more_clear_headers` vient du module `headers-more`, présent par
          # défaut dans le nginx de NixOS (aux côtés de `dav` et `rtmp`, vérifié
          # dans `nginx -V`) : aucun module à ajouter, aucune recompilation. Il
          # retire un en-tête précis d'une réponse d'amont, ce que nginx nu ne
          # sait pas faire — il ne sait que le cacher là où le `fastcgi_pass` a
          # lieu, ce qui frapperait aussi les vrais partages.
          #
          # `-s 404` n'est PAS optionnel, et son absence est un piège vérifié :
          # sans filtre de statut, `more_clear_headers` ne s'applique qu'à une
          # liste de codes CÂBLÉE dans le module (200, 201, 204, 206, 301, 302,
          # 303, 304, 307, 308) qui n'inclut pas le 404. La directive passait
          # alors le test de configuration sans rien effacer, et les cookies
          # `oc_sessionPassphrase` continuaient de trahir Nextcloud sur la page
          # censée être neutre.
          more_clear_headers -s 404 'Set-Cookie';

          # Ni marque, ni version, ni nom d'application. Le texte s'adresse à
          # quelqu'un dont le lien de partage ne marche pas : cette location
          # n'intercepte plus que les chemins de partage, qui ne renvoient 404
          # que sur un jeton absent ou expiré. `publicpreview` et `shareinfo` en
          # font partie mais leur corps n'est jamais lu par un humain — c'est le
          # cas `/s/` qui compte.
          return 404 '${
            myLib.mkErrorPage {
              title = "Lien introuvable";
              body = ''
                <p>Ce lien de partage n&rsquo;existe pas, ou il a expir&eacute;.</p>
                <p>Redemande-en un &agrave; la personne qui te l&rsquo;a envoy&eacute;.</p>'';
            }
          }';
        '';
      })

      # Portail d'authentification devant le vhost, quand il est activé.
      #
      # UN seul nom, deux chemins, et c'est Authelia qui les distingue — sur
      # l'adresse source, par ses règles `networks` (cf. default.nix). Depuis le
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
