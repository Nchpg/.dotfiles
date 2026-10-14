{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Grafana : l'interface pour regarder les courbes et les journaux. Il ne fait
# que regarder — rien de ce qui prévient ne dépend de lui. Le tableau de bord
# lui-même est dans dashboard.nix.
let
  cfg = config.systemSettings.monitoring;
  authelia = config.systemSettings.authelia;
  inherit (cfg.internal) ports;
in
{
  config = lib.mkIf cfg.enable {
    services.grafana = {
      enable = true;

      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = ports.grafana;
          domain = cfg.grafana.hostName;
          # Sans lui, les liens que Grafana fabrique (partage, retour de
          # connexion) pointent vers localhost:3000.
          root_url = "https://${cfg.grafana.hostName}/";

          # COMPRESSION DES RÉPONSES, coupée par défaut chez Grafana. Ce qui
          # transite ici est du JSON — la définition du tableau, puis chaque
          # réponse de requête —, c'est-à-dire ce qui se compresse le mieux.
          #
          # Le chemin justifie la dépense de processeur : depuis l'extérieur, une
          # réponse traverse le tunnel Cloudflare avant d'arriver sur un
          # téléphone en 4G, et c'est exactement la situation où l'on ouvre ce
          # tableau — une alerte vient de tomber, on n'est pas chez soi.
          enable_gzip = true;
        };

        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          feedback_links_enabled = false;
        };
        news.news_feed_enabled = false;

        # L'AUTRE VÉRIFICATEUR DE MISES À JOUR, distinct de celui d'`analytics`
        # juste au-dessus, qui ne couvre que Grafana lui-même. Celui-ci interroge
        # grafana.com pour les GREFFONS, toutes les dix minutes, et il reste actif
        # quand l'autre est coupé — relevé dans le journal, pas supposé :
        #
        #   logger=plugins.update.checker msg="Update check succeeded"
        #
        # Aucun greffon n'est installé sur cette instance, donc la requête
        # demande l'état de rien. Même raison que le phone home de Loki : une
        # machine de la maison n'ouvre pas de connexion sortante que personne n'a
        # demandée.
        plugins.check_for_updates = false;

        # MÊME RAISONNEMENT QUE POUR LOKI : en `info`, Grafana écrit des milliers
        # de lignes par jour dans le journal, dont aucune au-dessus d'`info` —
        # des évictions de cache d'index, des évaluations de drapeaux internes.
        # C'est une part notable du volume de la machine, produite par la brique
        # qui sert justement à LIRE ce journal.
        #
        # Ce qu'on garde : tout ce qui compte vraiment est au-dessus d'`info`.
        # Une erreur de provisioning — un tableau de bord illisible, une source
        # de données refusée — sort en `error` et reste visible.
        log.level = "warn";

        # AUTHENTIFICATION DÉLÉGUÉE AU PORTAIL, et c'est le point le plus délicat
        # du module.
        #
        # Le principe : Authelia authentifie, nginx transmet l'identité dans un
        # en-tête, Grafana fait confiance à cet en-tête et ouvre la session. Plus
        # aucun mot de passe Grafana à gérer, donc plus aucun secret de plus dans
        # sops, et une seule connexion au lieu de deux.
        #
        # CE QUI LE REND SÛR tient à trois conditions, toutes vérifiables :
        #
        #   1. Grafana n'écoute que sur 127.0.0.1 : personne ne peut lui parler
        #      sans passer par nginx.
        #   2. nginx pose l'en-tête avec `proxy_set_header`, qui REMPLACE ce que
        #      le client a envoyé. Un visiteur qui fabrique un `X-WEBAUTH-USER`
        #      le voit écrasé par la valeur qu'Authelia a renvoyée (cf. le vhost
        #      plus bas).
        #   3. `whitelist` restreint la confiance à la boucle locale, seule
        #      adresse d'où nginx se connecte.
        #
        # Retirer l'une des trois suffit à transformer un en-tête en droit
        # d'administration.
        "auth.proxy" = {
          enabled = true;
          header_name = "X-WEBAUTH-USER";
          header_property = "username";
          headers = "Name:X-WEBAUTH-NAME Email:X-WEBAUTH-EMAIL";
          auto_sign_up = true;
          sync_ttl = 60;
          whitelist = "127.0.0.1";
          enable_login_token = false;
        };

        auth = {
          # Formulaire de connexion COUPÉ : le laisser afficherait une porte
          # dérobée protégée par le mot de passe admin par défaut de Grafana.
          #
          # CONTREPARTIE, à connaître avant d'en avoir besoin : si Authelia cesse
          # de renvoyer l'identité, plus personne n'entre, y compris par un
          # tunnel SSH vers 127.0.0.1:3000. La porte de secours est de remettre
          # cette ligne à `false` le temps d'un rebuild, puis
          # `grafana-cli admin reset-admin-password <mot de passe>`.
          disable_login_form = true;
          disable_signout_menu = true;
        };
        "auth.anonymous".enabled = false;
        "auth.basic".enabled = false;

        users = {
          allow_sign_up = false;

          # `Editor` ET NON `Admin`, et l'écart est plus grand qu'il n'y paraît.
          #
          # Ce qu'un Editor peut faire couvre tout l'usage réel : explorer les
          # métriques, écrire des requêtes, créer et modifier des tableaux de
          # bord. Ce qu'il ne peut PAS faire est précisément ce qui est dangereux
          # ici — AJOUTER UNE SOURCE DE DONNÉES. Grafana interroge ses sources
          # depuis le serveur, donc quiconque peut en déclarer une fait émettre à
          # cette machine des requêtes vers l'adresse de son choix, y compris des
          # services de la boucle locale qui ne sont exposés nulle part :
          # Prometheus, Alertmanager, l'API d'Authelia. C'est un relais de
          # requêtes complet, offert par une interface graphique.
          #
          # Ça ne coûte rien parce que les sources sont POSÉES PAR LE DÉPÔT juste
          # en dessous : il n'y a jamais eu de raison d'en ajouter à la main.
          #
          # La barrière principale reste la règle Authelia, qui doit désigner
          # NOMMÉMENT les comptes admis (`subject`) — les comptes familiaux ont
          # eux aussi accès au portail. Celle-ci en est la seconde, pour le jour
          # où la première serait relâchée par inadvertance.
          auto_assign_org_role = "Editor";
        };

        security = {
          cookie_secure = true;

          # Clé qui chiffre les secrets rangés dans la base de Grafana — mots de
          # passe de sources de données, jetons de points de contact. Depuis
          # 26.05 elle n'a plus de valeur par défaut, et le module amont refuse
          # de construire sans elle.
          #
          # NI EN CLAIR ICI, NI DANS SOPS, mais engendrée sur la machine au
          # premier démarrage (cf. le preStart plus bas). En clair, elle finirait
          # dans le store et dans ce dépôt public, ce qui reviendrait à ne rien
          # chiffrer. Dans sops, elle laisserait croire à un secret transportable
          # alors qu'elle ne vaut QUE pour la base qu'elle a chiffrée : la
          # restaurer sur une machine dont la base est vide n'apporte rien, et la
          # perdre en gardant la base rend celle-ci illisible. Clé et base sont
          # le même état local, elles vivent au même endroit.
          #
          # `$__file{}` est le mécanisme de Grafana lui-même : il lit le contenu
          # du fichier au démarrage.
          secret_key = "$__file{${config.services.grafana.dataDir}/secret_key}";
        };
      };

      # Sources et tableaux de bord POSÉS PAR LE DÉPÔT, jamais cliqués. C'est ce
      # qui fait qu'une réinstallation rend une instance identique et pas une
      # instance vide — le reproche principal qu'on peut faire aux outils dont
      # toute la configuration vit dans une base.
      provision = {
        enable = true;

        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              # `uid` FIXE, et c'est ce qui rend le tableau de bord portable : un
              # panneau référence sa source par uid, et un uid engendré au hasard
              # changerait à chaque réinstallation, laissant des panneaux vides.
              uid = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.prometheus}";
              isDefault = true;
              jsonData.timeInterval = cfg.scrapeInterval;
            }
            {
              name = "Alertmanager";
              type = "alertmanager";
              uid = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString ports.alertmanager}";
              jsonData.implementation = "prometheus";
            }
          ]
          ++ lib.optional cfg.logs.enable {
            name = "Loki";
            type = "loki";
            # `uid` fixe pour la même raison que les deux au-dessus.
            uid = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString ports.loki}";
          };
        };
      };
    };

    # ------------------------------------------------------------- publication

    services.nginx.virtualHosts.${cfg.grafana.hostName} = lib.mkMerge [
      (myLib.mkTlsVhost {
        # Adresse réelle plutôt que celle de la connexion TCP, comme le portail :
        # tout arrive par cloudflared en 127.0.0.1 quand on vient de l'extérieur.
        extraConfig = ''
          access_log /var/log/nginx/access.log cf_combined;
        '';

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString ports.grafana}";
          # Grafana Live pousse ses mises à jour par websocket.
          proxyWebsockets = true;

          extraConfig = ''
            # LES DEUX LIGNES CI-DESSOUS SONT RECOPIÉES du niveau server, où
            # `authelia.nginxProtect` les pose déjà. Ce n'est pas une redondance,
            # c'est une obligation : `auth_request_set` suit la même règle
            # d'héritage que `add_header`, à savoir qu'un niveau qui en déclare
            # UN SEUL REMPLACE toute la liste du parent au lieu de s'y ajouter.
            #
            # Les trois `auth_request_set` de l'identité, juste en dessous,
            # suffisaient donc à effacer ceux du parent. `$redirection_url`
            # restait vide, `@authelia_401` en concluait que le 401 venait de
            # l'application et servait un 401 sec — en avalant la redirection
            # vers le portail qu'Authelia avait pourtant renvoyée. Symptôme :
            # 401 sans en-tête `Location` sur un nom protégé, alors que le même
            # montage marche sur Nextcloud, dont le vhost n'ajoute aucun
            # `auth_request_set`. Constaté par la sonde blackbox.
            #
            # SI TU AJOUTES un `auth_request_set` ici, vérifie que ces deux-là y
            # sont toujours.
            auth_request_set $redirection_url $upstream_http_location;
            auth_request_set $auth_status $upstream_status;

            # IDENTITÉ RENVOYÉE PAR AUTHELIA, reprise de la sous-requête
            # d'autorisation et repassée à Grafana. `$upstream_http_remote_user`
            # est l'en-tête `Remote-User` de la RÉPONSE d'Authelia — donc une
            # valeur qu'il a produite, pas une valeur que le client a envoyée.
            auth_request_set $authelia_user $upstream_http_remote_user;
            auth_request_set $authelia_name $upstream_http_remote_name;
            auth_request_set $authelia_email $upstream_http_remote_email;

            # `proxy_set_header` REMPLACE l'en-tête du client, il ne s'y ajoute
            # pas : c'est ce qui rend l'identité infalsifiable depuis dehors.
            # Ne jamais retirer ces trois lignes en laissant `auth.proxy` actif,
            # ce serait ouvrir l'administration de Grafana à un en-tête.
            proxy_set_header X-WEBAUTH-USER $authelia_user;
            proxy_set_header X-WEBAUTH-NAME $authelia_name;
            proxy_set_header X-WEBAUTH-EMAIL $authelia_email;
          '';
        };
      })

      # Portail devant le vhost. `nginxProtect` et non `nginxAuthRequest` :
      # contrairement à Nextcloud, rien derrière n'émet de 401 qu'il faudrait
      # préserver — le formulaire de connexion de Grafana est coupé, c'est
      # Authelia qui refuse, et sa redirection doit être suivie.
      authelia.nginxProtect
    ];

    systemSettings.cloudflared = lib.mkIf cfg.grafana.public {
      ingress.${cfg.grafana.hostName} = "https://127.0.0.1:443";
    };

    # Engendre la clé de chiffrement de la base au premier démarrage, et
    # seulement s'il n'y en a pas : la RÉÉCRIRE rendrait illisible tout ce
    # qu'elle a déjà chiffré.
    #
    # `mkAfter` : le module amont a son propre preStart, qui pose les liens
    # vers les ressources de Grafana. On s'ajoute derrière au lieu de le
    # remplacer.
    systemd.services.grafana.preStart =
      let
        bin = "${pkgs-stable.coreutils}/bin";
      in
      lib.mkAfter ''
        key=${config.services.grafana.dataDir}/secret_key
        if [ ! -s "$key" ]; then
          umask 077
          # Sans saut de ligne final : Grafana lit le fichier tel quel.
          ${bin}/head -c 32 /dev/urandom \
            | ${bin}/base64 \
            | ${bin}/tr -d '\n' > "$key"
          ${bin}/chmod 0400 "$key"
        fi
      '';

    # Grafana n'est même pas collecté : le signalement d'échec d'unité est son
    # SEUL filet.
    systemSettings.notify.discord.units = [ "grafana" ];
  };
}
