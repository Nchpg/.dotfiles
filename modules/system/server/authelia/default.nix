{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Portail d'authentification devant les services publiés par le tunnel :
# équivalent auto-hébergé de Cloudflare Access. nginx interroge Authelia
# (`auth_request`) avant de servir quoi que ce soit, et redirige vers le portail
# si la session manque.
#
# À savoir avant de s'y fier : Authelia n'a JAMAIS eu d'audit de sécurité
# indépendant. Son historique est bon — sept avis depuis 2021, surtout de
# gravité faible — mais le seul classé High, en 2021, était un contournement
# d'authentification spécifique à l'intégration nginx. D'où le parti pris de
# reprendre l'extrait officiel du projet sans rien improviser : la fragilité est
# là, pas dans Authelia lui-même.
let
  cfg = config.systemSettings.authelia;
  inherit (cfg) port;

  mail = config.systemSettings.mail;

  instanceDir = "/var/lib/authelia-main";

  # Fichier d'utilisateurs VIVANT, qu'Authelia peut réécrire, par opposition à
  # celui de sops qui est en lecture seule.
  liveUsers = "${instanceDir}/users.yml";
  seedUsers = config.sops.secrets."authelia/users".path;

  # Au sens strict : le domaine lui-même ou un de ses sous-domaines. Un simple
  # `hasSuffix` accepterait `malexemple.fr` sous `exemple.fr`.
  isUnder = domain: host: host == domain || lib.hasSuffix ".${domain}" host;

  # Point de contrôle interrogé par nginx avant de servir. Chaque en-tête ci-
  # dessous porte une décision de sécurité, et le bloc est identique pour tous
  # les services protégés : il vit ici plutôt que recopié dans chaque module.
  authzLocation = {
    proxyPass = "http://127.0.0.1:${toString cfg.port}/api/authz/auth-request";

    # COUPÉ, pour la même raison que sur le vhost du portail plus bas, sauf
    # qu'ici l'enjeu n'est pas le journal mais la DÉCISION D'ACCÈS.
    #
    # La liste recommandée pose `X-Forwarded-For $proxy_add_x_forwarded_for`, et
    # nginx n'écrase pas un `proxy_set_header` par un autre de même nom : il
    # émet l'en-tête DEUX FOIS. Authelia lit le premier, donc tout tenait à
    # l'ordre dans lequel le module nginx de nixpkgs rend la location — il place
    # `extraConfig` avant l'include, ce qui met par chance la bonne valeur
    # devant. Vérifié sur la configuration construite.
    #
    # C'est un détail cosmétique amont que personne ne garde. S'il s'inverse, la
    # première entrée devient celle que l'appelant a envoyée, et les règles
    # `networks:` — donc le contournement du portail depuis le LAN et le VPN —
    # deviennent forgeables par un simple en-tête à travers le tunnel. On ne
    # laisse pas une décision d'autorisation reposer là-dessus.
    #
    # Les en-têtes que l'include apportait et qui servent encore sont réécrits
    # ci-dessous. `X-Forwarded-Server` est le seul abandonné : Authelia ne le lit
    # nulle part.
    recommendedProxySettings = false;

    extraConfig = ''
      internal;
      # Sans ça, le point de contrôle s'interrogerait lui-même : la directive
      # auth_request du bloc server est héritée par toutes les locations,
      # celle-ci comprise.
      auth_request off;

      # Repris tels quels de la liste recommandée qu'on vient de couper, aux
      # mêmes valeurs : sans `Host`, nginx annoncerait `127.0.0.1:9091` à
      # Authelia. Aucun des trois ne décide de quoi que ce soit ici, la décision
      # se joue sur X-Original-URL et X-Forwarded-For.
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;

      proxy_set_header X-Original-Method $request_method;
      proxy_set_header X-Original-URL $scheme://$http_host$request_uri;

      # PIÈCE MAÎTRESSE de la distinction local/public : Authelia décide de ses
      # règles `networks:` d'après cet en-tête, et `$remote_addr` est l'adresse
      # TCP réelle du pair, que le client ne peut pas fabriquer.
      #
      # C'est l'inverse du `$proxy_add_x_forwarded_for` habituel, qui CONCATÈNE
      # et laisserait n'importe qui annoncer une adresse du LAN pour obtenir le
      # contournement. Ne pas remplacer l'un par l'autre.
      #
      # Et surtout : ne pas laisser un SECOND `proxy_set_header X-Forwarded-For`
      # apparaître dans cette location. nginx n'écrase pas, il émet l'en-tête
      # autant de fois qu'il est déclaré, et Authelia lit le premier. C'est
      # exactement ce que faisait la liste recommandée, d'où le
      # `recommendedProxySettings = false` plus haut.
      proxy_set_header X-Forwarded-For $remote_addr;

      # En-tête Authorization VIDÉ pour la sous-requête, et c'est essentiel :
      # Authelia honore l'authentification basique sur ce point d'entrée, donc
      # il voit l'en-tête que le client destinait à l'application, cherche ce
      # compte dans SON fichier d'utilisateurs et répond 401. Symptôme observé
      # sur Nextcloud : « failed to retrieve user details for user admin: user
      # not found » côté Authelia, et un 401 inexplicable côté navigateur.
      #
      # Vider l'en-tête ICI n'affecte que la sous-requête : la requête
      # principale le transmet intact à l'application, qui reste seule juge de
      # ses propres identifiants.
      proxy_set_header Authorization "";

      # La décision ne dépend jamais du corps de la requête : ne pas le
      # transmettre évite d'envoyer chaque téléversement à Authelia.
      proxy_set_header Content-Length "";
      proxy_pass_request_body off;
    '';
  };
in
{
  options.systemSettings.authelia = {
    enable = lib.mkEnableOption "portail d'authentification Authelia";

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "exemple.fr";
      description = ''
        Domaine porteur du cookie de session. Il doit être un PARENT commun du
        portail et de tous les services protégés, sinon le cookie posé par le
        portail n'accompagne pas les requêtes vers le service et l'utilisateur
        boucle indéfiniment sur la page de connexion.

        À prendre le plus ÉTROIT possible en principe : un cookie de session est
        transmis au domaine et à tous ses sous-domaines, donc le poser sur la
        racine l'envoie aussi au site public et à tout ce qui y sera hébergé.

        MAIS le resserrer suppose de loger le portail un cran plus bas
        (auth.cloud.exemple.fr), et ça ne marche PAS derrière le plan gratuit de
        Cloudflare : son certificat Universal SSL ne couvre que `*.exemple.fr` et
        un joker DNS ne vaut que pour un niveau. Leur edge ne présente alors
        aucun certificat valide et la connexion échoue avant d'atteindre le
        tunnel ; couvrir deux niveaux exige Advanced Certificate Manager, payant.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9091;
      description = ''
        Port de bouclage d'Authelia, jamais joint directement de l'extérieur :
        seuls nginx (pour `auth_request`) et le vhost du portail s'y adressent.
        Exposé en option pour que les modules protégés le reprennent d'ici
        plutôt que de le réécrire en dur.
      '';
    };

    portalHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "auth.exemple.fr";
      description = ''
        Nom du portail. Il doit être publié par le tunnel au même titre que les
        services protégés : la redirection d'authentification se produit dans le
        navigateur du visiteur, qui doit donc pouvoir l'atteindre.
      '';
    };

    defaultRedirect = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://cloud.exemple.fr";
      description = ''
        Où envoyer quelqu'un qui s'authentifie sans destination connue : arrivée
        directe sur le portail, et surtout retour d'un lien d'enrôlement du
        second facteur, qui ne transporte pas le paramètre `rd` de la requête
        d'origine. Sans ce réglage, on reste bloqué sur le portail après une
        authentification pourtant réussie.
      '';
    };

    mutableUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Laisse Authelia RÉÉCRIRE son fichier d'utilisateurs, ce qui active le
        changement et la réinitialisation de mot de passe depuis le portail.

        Sans ça, le fichier vient de sops et vit en lecture seule : les mots de
        passe sont figés et personne ne peut changer le sien.

        Avec, sops ne fait plus que SEMER — tout compte déclaré et absent du
        fichier vivant y est ajouté, les entrées existantes ne sont jamais
        touchées. C'est la sémantique de `mutableUsers` de NixOS pour les comptes
        système. Le champ `password` peut alors être omis : le semeur en génère
        un aléatoire que personne ne lit, et la personne entre par « mot de passe
        oublié ».

        DEUX CONSÉQUENCES à assumer. Le fichier vivant devient un état hors du
        dépôt, contenant les hachages de tout le monde, donc à sauvegarder. Et
        RETIRER quelqu'un de sops ne le supprime plus : la révocation cesse
        d'être déclarative et demande d'éditer le fichier vivant à la main.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "error"
        "warn"
        "info"
        "debug"
        "trace"
      ];
      default = "info";
      description = ''
        Verbosité du journal. `info` ne trace que les échecs, ce qui rend
        invisible tout ce qui réussit — passer en `debug` le temps de reproduire
        un problème, puis revenir. `trace` consigne jusqu'au contenu des
        requêtes, en-têtes d'authentification compris.
      '';
    };

    rules = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = [ ];
      example = [
        {
          domain = "cloud.exemple.fr";
          policy = "two_factor";
        }
      ];
      description = ''
        Règles de contrôle d'accès, dans l'ordre : la première qui correspond
        gagne. La politique par défaut est `deny`, donc tout service protégé doit
        avoir sa règle ici.
      '';
    };

    nginxAuthRequest = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = {
        extraConfig = ''
          auth_request /internal/authelia/authz;
          auth_request_set $redirection_url $upstream_http_location;
        '';
        locations."/internal/authelia/authz" = authzLocation;
      };
      defaultText = lib.literalExpression "le point de contrôle et sa directive auth_request";
      description = ''
        SOCLE à fusionner dans le vhost d'un service à protéger : la directive
        `auth_request` et le point de contrôle interne qu'elle interroge.

        Volontairement SANS politique sur le 401 : c'est la seule pièce qui
        diffère d'un service à l'autre, et se tromper là ouvre ou casse le
        service en silence. Un service dont l'application n'émet jamais de 401
        elle-même prendra plutôt `nginxProtect`, qui ajoute la redirection.
        Nextcloud ne le peut pas, son WebDAV répondant lui-même 401.
      '';
    };

    nginxProtect = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = {
        extraConfig = config.systemSettings.authelia.nginxAuthRequest.extraConfig + ''
          # Statut de la SOUS-REQUÊTE, seul moyen de distinguer un refus
          # d'Authelia d'un code que l'application produit elle-même.
          auth_request_set $auth_status $upstream_status;

          error_page 401 = @authelia_401;
          error_page 403 = @authelia_403;
        '';
        locations = config.systemSettings.authelia.nginxAuthRequest.locations // {
          # Le 401 ne peut PAS être réécrit en 302 sans discernement. Authelia
          # joint un en-tête Location quand il refuse, et il faut rediriger ;
          # mais l'application derrière peut répondre 401 pour ses propres
          # raisons — une SPA qui interroge son API sans session, un client
          # WebDAV — et `$redirection_url` est alors vide. Rediriger quand même
          # produirait un 302 avec un Location VIDE, que rien ne sait suivre.
          "@authelia_401".extraConfig = ''
            internal;
            auth_request off;

            if ($redirection_url != "") {
              return 302 $redirection_url;
            }

            return 401;
          '';

          # Refus après authentification : le compte est connu mais aucune règle
          # ne l'autorise, donc `default_policy = deny`. Sans cette page, nginx
          # sert son 403 brut, qui ne dit pas à la personne que son compte est
          # simplement hors périmètre.
          #
          # Conditionné à `$auth_status` pour la même raison que ci-dessus : un
          # 403 émis par l'application ne doit pas être remplacé par une page qui
          # parlerait d'autorisation Authelia.
          "@authelia_403".extraConfig = ''
            internal;
            auth_request off;
            default_type text/html;

            if ($auth_status = 403) {
              return 403 '<!doctype html>
            <html lang="fr"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Accès refusé</title>
            <style>
            :root{color-scheme:light dark}
            body{margin:0;min-height:100vh;display:grid;place-items:center;padding:2rem;
              font:16px/1.6 system-ui,-apple-system,sans-serif;background:#fafafa;color:#1a1a1a}
            main{max-width:30rem;text-align:center}
            h1{font-size:1.4rem;margin:0 0 1rem;font-weight:600}
            p{margin:0 0 .75rem;color:#5a5a5a}
            a{color:#3f7078}
            @media(prefers-color-scheme:dark){
              body{background:#171717;color:#ededed}p{color:#a3a3a3}a{color:#7fb3bb}}
            </style></head><body><main>
            <h1>Accès refusé</h1>
            <p>Ton compte est bien authentifié, mais il n&rsquo;est pas autorisé à
            ouvrir ce service.</p>
            <p>Si tu penses que c&rsquo;est une erreur, demande à
            l&rsquo;administrateur.</p>
            ${lib.optionalString (
              cfg.portalHost != null
            ) ''<p><a href="https://${cfg.portalHost}/logout">Se déconnecter et changer de compte</a></p>''}
            </main></body></html>';
            }

            return 403;
          '';
        };
      };
      defaultText = lib.literalExpression "nginxAuthRequest, plus le traitement des refus 401 et 403";
      description = ''
        Fragment de vhost COMPLET : le socle, la redirection vers le portail sur
        un refus d'Authelia, et une page lisible quand le compte est authentifié
        mais hors périmètre.

        Les deux traitements sont CONDITIONNELS, et c'est ce qui les rend
        réutilisables : ils ne s'appliquent qu'aux codes venus d'Authelia, jamais
        à ceux de l'application derrière.

        Nextcloud n'emploie pas cette option : ses réponses 401 doivent en plus
        réémettre les en-têtes de sécurité que le module amont pose sur le vhost,
        un `add_header` de location remplaçant toute la liste du parent. Il part
        donc de `nginxAuthRequest`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null && cfg.portalHost != null;
        message = "systemSettings.authelia : domain (parent commun pour le cookie) et portalHost (nom du portail) sont requis.";
      }
      {
        # Toutes les assertions s'évaluent, y compris quand une précédente
        # échoue : le garde sur null évite une erreur d'éval opaque à la place
        # du message ci-dessus.
        assertion = cfg.domain == null || cfg.portalHost == null || isUnder cfg.domain cfg.portalHost;
        message = "systemSettings.authelia : portalHost doit être sous domain, sinon le cookie de session ne lui sera jamais envoyé.";
      }
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.authelia exige systemSettings.proxy.enable (nginx et le certificat du portail).";
      }
    ];

    # Valeurs à générer avec `openssl rand -hex 32`, une par secret, JAMAIS la
    # même : elles protègent des choses différentes.
    #
    # `restartUnits` n'est PAS décoratif. Authelia lit ces fichiers une fois au
    # démarrage et ne les surveille pas ; or un changement de secret ne modifie
    # pas l'unité systemd, donc un rebuild régénère le fichier sans rien
    # redémarrer. Ajouter un utilisateur restait alors sans effet et le portail
    # répondait « user not found » sur un compte pourtant présent dans sops.
    sops.secrets =
      let
        forAuthelia = {
          owner = "authelia-main";
          # Le semeur figure ici aussi : sans lui, ajouter un compte dans sops
          # ne le recopierait pas dans le fichier vivant.
          restartUnits = [
            "authelia-main.service"
          ]
          ++ lib.optional cfg.mutableUsers "authelia-seed-users.service";
        };
      in
      {
        "authelia/jwt_secret" = forAuthelia;
        "authelia/storage_key" = forAuthelia;
        # Chiffre le contenu des sessions, que Redis ne voit alors que comme des
        # octets opaques. Requis dès lors qu'elles y sont stockées (ci-dessous).
        "authelia/session_secret" = forAuthelia;
        # Fichier d'utilisateurs au format Authelia (mots de passe hachés en
        # argon2id, générés par `authelia crypto hash generate argon2`).
        "authelia/users" = forAuthelia;
      };

    # Instance Redis DÉDIÉE, et pas celle de Nextcloud : deux services qui
    # partagent un Redis lisent et écrivent les clés l'un de l'autre, donc une
    # faille dans Nextcloud donnerait accès aux sessions d'authentification,
    # c'est-à-dire au moyen de contourner Authelia.
    #
    # Socket unix et pas TCP : rien n'écoute sur le réseau, même en local.
    services.redis.servers.authelia = {
      enable = true;
      port = 0;
      unixSocket = "/run/redis-authelia/redis.sock";
      unixSocketPerm = 660;
    };

    # `redis-authelia` pour le socket des sessions, `smtp` pour le mot de passe
    # du relais.
    users.users.authelia-main.extraGroups = [
      "redis-authelia"
    ]
    ++ lib.optional mail.enable "smtp";

    # Sème le fichier vivant depuis sops : ajoute ce qui manque, ne touche JAMAIS
    # à ce qui existe. Un mot de passe posé par un utilisateur survit donc aux
    # rebuilds, ce qui est tout l'objet de mutableUsers.
    systemd.services.authelia-seed-users = lib.mkIf cfg.mutableUsers {
      description = "Sème le fichier d'utilisateurs Authelia depuis sops";
      before = [ "authelia-main.service" ];
      requiredBy = [ "authelia-main.service" ];
      path = [
        pkgs-stable.yq-go
        config.services.authelia.instances.main.package
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "authelia-main";
        StateDirectory = "authelia-main";
      };
      script = ''
        set -euo pipefail

        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT

        if [ -e ${liveUsers} ]; then
          # L'ordre de fusion est significatif : l'opérande de DROITE gagne,
          # d'où le fichier vivant en second.
          yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            ${seedUsers} ${liveUsers} > "$tmp"
        else
          cp ${seedUsers} "$tmp"
        fi

        # Tout compte déclaré SANS mot de passe reçoit ici le haché d'un aléa que
        # personne ne lit, pas même ce script. La personne entre par « mot de
        # passe oublié » et pose le sien, qui survivra aux rebuilds grâce à la
        # fusion ci-dessus. Ça retire les mots de passe de sops, où l'on ne
        # déclare plus qu'une identité.
        for user in $(yq -r '(.users // {}) | keys | .[]' "$tmp"); do
          current=$(yq -r ".users.\"$user\".password // \"\"" "$tmp")
          if [ -z "$current" ] || [ "$current" = "null" ]; then
            digest=$(authelia crypto hash generate argon2 --random \
              | sed -n 's/^Digest: //p')
            yq -i ".users.\"$user\".password = \"$digest\"" "$tmp"
            echo "compte '$user' : mot de passe initial aléatoire, à poser via « mot de passe oublié »"
          fi
        done

        install -m 0600 "$tmp" ${liveUsers}
      '';
    };

    services.authelia.instances.main = {
      enable = true;

      # Par fichier et non en clair dans la configuration : celle-ci finit dans
      # le store, lisible par tous les utilisateurs de la machine.
      environmentVariables = lib.mkIf mail.enable {
        AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE = config.sops.secrets.${mail.passwordKey}.path;
      };

      secrets = {
        jwtSecretFile = config.sops.secrets."authelia/jwt_secret".path;
        storageEncryptionKeyFile = config.sops.secrets."authelia/storage_key".path;
        sessionSecretFile = config.sops.secrets."authelia/session_secret".path;
      };

      settings = {
        theme = "auto";

        server.address = "tcp://127.0.0.1:${toString port}";

        log.level = cfg.logLevel;

        authentication_backend.file = {
          # Le fichier vivant quand Authelia doit pouvoir le réécrire, celui de
          # sops sinon. C'est ce seul chemin qui décide si le changement de mot
          # de passe fonctionne : sur /run/secrets, l'écriture échoue.
          path = if cfg.mutableUsers then liveUsers else seedUsers;
          password.algorithm = "argon2";
        };

        session = {
          cookies = [
            (
              {
                domain = cfg.domain;
                authelia_url = "https://${cfg.portalHost}";
              }
              // lib.optionalAttrs (cfg.defaultRedirect != null) {
                default_redirection_url = cfg.defaultRedirect;
              }
            )
          ];

          # Sessions persistées : en mémoire, tout le monde se reconnecte à
          # chaque redémarrage d'Authelia, donc à chaque rebuild qui le touche —
          # y compris ceux que fait autoUpgrade la nuit.
          redis.host = config.services.redis.servers.authelia.unixSocket;

          # Durées posées explicitement : les défauts d'Authelia (cinq minutes
          # d'inactivité, une heure au total) visent un usage bureautique
          # surveillé et redemandent le second facteur sans cesse.
          #
          # Le curseur se règle ici. Rallonger, c'est laisser une session ouverte
          # plus longtemps sur un appareil qu'on peut se faire voler ;
          # raccourcir, c'est finir par cocher « se souvenir de moi » partout, ce
          # qui est pire.
          expiration = "12h";
          inactivity = "2h";
          remember_me = "1M";
        };

        # Bannissement après échecs répétés, posé explicitement : c'est la seule
        # protection contre la force brute sur le portail, désormais la porte
        # d'entrée publique.
        regulation = {
          max_retries = 3;
          find_time = "2m";
          ban_time = "10m";
        };

        storage.local.path = "${instanceDir}/db.sqlite3";

        # Par SMTP si un relais est configuré, sinon dans un fichier. L'écart
        # n'est pas cosmétique : sans courrier, enrôler le second facteur de
        # quelqu'un d'autre oblige à se connecter en SSH pour aller pêcher son
        # lien dans ce fichier, puis à le lui transmettre.
        notifier =
          if mail.enable then
            {
              smtp = {
                # Clé `address` et non host/port : depuis 4.38 Authelia attend
                # une URL dont le schéma porte le mode de chiffrement.
                address = mail.url;
                username = mail.user;
                sender = "Authelia <${mail.from}>";
              };
            }
          else
            { filesystem.filename = "${instanceDir}/notification.txt"; };

        totp.issuer = cfg.domain;

        access_control = {
          # Refus par défaut : un service publié dont on aurait oublié la règle
          # est inaccessible, pas ouvert.
          default_policy = "deny";
          inherit (cfg) rules;
        };
      };
    };

    services.nginx.virtualHosts.${cfg.portalHost} = myLib.mkTlsVhost {
      # Journal à l'adresse réelle plutôt qu'à celle de la connexion TCP. Le
      # portail est la porte d'entrée publique, donc l'endroit où arrivent les
      # tentatives d'identifiants, et tout y était consigné comme venant de
      # 127.0.0.1 puisque c'est cloudflared qui se connecte. Attribution
      # seulement : la régulation d'Authelia compte par COMPTE, pas par adresse,
      # elle ne dépend pas de cette ligne. Cf. le format dans
      # modules/system/server/proxy.
      extraConfig = ''
        access_log /var/log/nginx/access.log cf_combined;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";

        # En-têtes écrits À LA MAIN, et `recommendedProxySettings` coupé pour
        # cette location. La liste recommandée pose
        # `X-Forwarded-For $proxy_add_x_forwarded_for`, qui CONCATÈNE la valeur
        # envoyée par le client : Authelia, qui retient le premier élément,
        # consignerait donc une adresse choisie par l'appelant.
        #
        # Et on ne peut pas se contenter d'ajouter la bonne ligne à côté :
        # vérifié, deux `proxy_set_header` de même nom dans une même location
        # émettent l'en-tête DEUX fois, et le premier gagne côté Authelia. Il
        # faut donc remplacer la liste, pas la compléter.
        #
        # Ce vhost est aussi le vhost par DÉFAUT du port 443 (premier bloc
        # déclaré, aucun `default_server` ailleurs), donc tout ce qui arrive avec
        # un Host inconnu atterrit ici : c'est la surface la plus exposée du
        # host, elle ne doit rien croire de ce que le client raconte.
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Connection "";
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-For $remote_addr;
        '';
      };
    };
  };
}
