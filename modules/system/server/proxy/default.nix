{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# nginx et certificats ACME : socle commun des services web du host. Les vhosts
# sont déclarés par les modules qui les SERVENT (cf. modules/system/server/nextcloud),
# pas ici.
let
  cfg = config.systemSettings.proxy;

  notify = config.systemSettings.notify.discord;

  certNames = lib.attrNames config.security.acme.certs;

  # Contrôle POSITIF, par opposition au `onFailure` posé plus bas sur les unités
  # de renouvellement. La distinction est le cœur de ce bloc.
  #
  # Une notification d'échec réagit à un ÉVÉNEMENT, donc elle ne peut rien dire
  # quand il ne se passe rien — et c'est exactement l'état d'une panne
  # silencieuse. Trois trous qu'elle ne voit pas :
  #
  #   - Le rechargement de nginx après un renouvellement réussi part en
  #     `systemctl --no-block try-reload-or-restart`. L'unité acme sort donc
  #     avec succès sans jamais savoir s'il a abouti. Certificat frais sur le
  #     disque, ancien certificat servi, expiration en silence.
  #   - Un timer qui ne se déclenche plus n'échoue pas. Le silence ressemble au
  #     succès.
  #   - nginx arrêté : le `try-` du rechargement ne fait rien, sans un mot.
  #
  # D'où une sonde qui vérifie un ÉTAT et non un événement : elle ouvre une
  # vraie connexion TLS sur la boucle locale et lit la date d'expiration du
  # certificat RÉELLEMENT SERVI. Sonder le point d'entrée plutôt que lire le
  # fichier attrape les trois cas d'un coup, puisque c'est ce que voit un client
  # qui compte, pas ce qu'il y a sur le disque.
  #
  # Elle ne notifie rien elle-même : elle SORT EN ERREUR, et le `onFailure`
  # ordinaire fait le reste. Une brique de moins à écrire, et la sonde reste
  # utilisable à la main.
  expiryCheck = pkgs-stable.writeShellApplication {
    name = "acme-expiry-check";
    runtimeInputs = with pkgs-stable; [
      openssl
      coreutils
    ];
    text = ''
      minDays=${toString cfg.expiryCheck.minDays}
      now=$(date +%s)
      limit=$((now + minDays * 86400))
      status=0

      for host in ${lib.concatStringsSep " " certNames}; do
        # `</dev/null` : sans lui s_client attend une saisie et ne rend jamais
        # la main. Le `timeout` couvre le cas ou nginx accepte la connexion
        # sans jamais terminer la poignee de main.
        if ! pem=$(timeout 10 openssl s_client -connect 127.0.0.1:443 \
                     -servername "$host" < /dev/null 2> /dev/null); then
          echo "$host : aucune reponse TLS sur 127.0.0.1:443" >&2
          status=1
          continue
        fi

        end=$(printf '%s' "$pem" | openssl x509 -noout -enddate 2> /dev/null | cut -d= -f2) || true
        if [ -z "$end" ]; then
          echo "$host : certificat servi illisible" >&2
          status=1
          continue
        fi

        if ! endts=$(date -d "$end" +%s 2> /dev/null); then
          echo "$host : date d'expiration illisible ($end)" >&2
          status=1
          continue
        fi

        days=$(( (endts - now) / 86400 ))
        if [ "$endts" -lt "$limit" ]; then
          echo "$host : expire dans $days jours, seuil a $minDays" >&2
          status=1
        else
          echo "$host : ok, $days jours restants"
        fi
      done

      exit "$status"
    '';
  };
in
{
  options.systemSettings.proxy = {
    enable = lib.mkEnableOption "reverse proxy nginx et certificats ACME";

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "moi@exemple.fr";
      description = ''
        Adresse de contact enregistrée sur le compte ACME. FACULTATIVE, et sans
        grand intérêt depuis le 4 juin 2025 : c'est la date à laquelle Let's
        Encrypt a cessé d'envoyer les avis d'expiration, qui étaient sa seule
        raison d'être. Le module amont ne passe `--email` à lego que si la
        valeur existe, `null` est donc parfaitement accepté.

        Ce qu'elle garde : le seul canal par lequel Let's Encrypt peut prévenir
        d'un incident, une révocation de masse par exemple — il y en a eu une en
        mars 2020, trois millions de certificats en quelques jours. Cas rare, et
        celui où l'on dispose d'heures et non de semaines.

        Elle ne remplace PAS une surveillance du renouvellement, qui se fait
        maintenant par `systemSettings.notify.discord` : sans elle, une panne de
        renouvellement réessaie chaque nuit sans un mot pendant trente jours,
        puis les navigateurs refusent la connexion.

        Une adresse de RÔLE sur le domaine plutôt qu'une adresse personnelle :
        ce dépôt est public, et une adresse une fois indexée ne se retire plus.
      '';
    };

    expiryCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Sonde quotidienne qui lit la date d'expiration du certificat
          RÉELLEMENT SERVI par nginx, et échoue si elle approche.

          Vrai par défaut, contrairement à l'usage de ce dépôt, parce que c'est
          la seule vérification qui ne dépend pas d'un événement : elle attrape
          le rechargement de nginx qui n'a pas eu lieu, le timer qui ne se
          déclenche plus, et nginx arrêté. Le `onFailure` sur les unités ACME ne
          voit aucun des trois.
        '';
      };

      minDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 21;
        description = ''
          Seuil d'alerte, en jours restants.

          Vingt et un et non trente : lego renouvelle dès qu'il reste moins d'un
          tiers de la durée de vie, soit trente jours sur un certificat de
          quatre-vingt-dix. Alerter à trente ferait donc sonner la sonde à
          chaque fenêtre de renouvellement normale. Vingt et un laisse neuf
          jours de tentatives silencieuses avant de crier, et encore trois
          semaines pour réagir.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Fréquence de la sonde, au format `OnCalendar` de systemd.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkInternalPorts config { tcp = [ 443 ]; })

      {
        # Plus d'assertion sur `acmeEmail`. Elle exigeait une adresse au motif
        # qu'« une panne de renouvellement ne se signale nulle part » sans elle,
        # ce qui n'est plus vrai depuis que Let's Encrypt a arrêté ses avis
        # d'expiration : elle ne se signalait déjà plus nulle part AVEC. Ce qui
        # la signale est l'avertissement ci-dessous, et le `onFailure` posé sur
        # les unités de renouvellement.
        warnings = lib.optional (!config.systemSettings.notify.discord.enable) ''
          systemSettings.proxy : aucune surveillance du renouvellement ACME sur ce host.
          Les avis d'expiration de Let's Encrypt ont cessé le 4 juin 2025, et lego réessaie
          en silence pendant les trente jours qui précèdent l'expiration — la panne se
          découvre donc quand les navigateurs refusent la connexion.
          Active systemSettings.notify.discord.
        '';

        # Les DEUX unités de chaque certificat, parce qu'elles échouent pour des
        # raisons différentes : `acme-<nom>` s'exécute à l'activation et au
        # démarrage, `acme-order-renew-<nom>` porte l'appel à lego et c'est celle
        # que le timer quotidien déclenche. Ne surveiller que la seconde
        # laisserait passer un certificat qui n'arrive même pas à être émis.
        #
        # Dérivé de `security.acme.certs` plutôt qu'écrit à la main : les noms
        # viennent des vhosts qui posent `enableACME`, donc une liste recopiée
        # ici cesserait d'être juste au premier service ajouté, sans rien dire.
        systemd.services = lib.mkMerge [
          (lib.mkIf notify.enable (
            lib.listToAttrs (
              lib.concatMap (cert: [
                (lib.nameValuePair "acme-${cert}" notify.onFailure)
                (lib.nameValuePair "acme-order-renew-${cert}" notify.onFailure)
              ]) certNames
            )
          ))

          # nginx et le tunnel, qui cassent HTTPS sans qu'aucun certificat soit
          # en cause. Deux lignes, et elles couvrent une panne que la sonde ne
          # verrait qu'au prochain passage quotidien.
          (lib.mkIf notify.enable {
            nginx = notify.onFailure;
          })

          (lib.mkIf cfg.expiryCheck.enable {
            acme-expiry-check = {
              description = "Vérifie la date d'expiration des certificats servis";

              # `after` et non `requires` : si nginx est arrêté, on VEUT que la
              # sonde tourne et échoue, c'est précisément l'un des cas qu'elle
              # existe pour attraper.
              after = [
                "nginx.service"
                "network-online.target"
              ];
              wants = [ "network-online.target" ];

              serviceConfig = {
                Type = "oneshot";
                ExecStart = lib.getExe expiryCheck;
                DynamicUser = true;
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateDevices = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
              };
            }
            // lib.optionalAttrs notify.enable notify.onFailure;
          })
        ];

        systemd.timers.acme-expiry-check = lib.mkIf cfg.expiryCheck.enable {
          description = "Sonde quotidienne d'expiration des certificats";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.expiryCheck.interval;
            # Rattrape le passage manqué si la machine était éteinte, sans quoi
            # une absence prolongée créerait le trou que la sonde doit fermer.
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        };

        services.nginx = {
          enable = true;
          recommendedTlsSettings = true;
          recommendedOptimisation = true;
          recommendedGzipSettings = true;
          recommendedProxySettings = true;
          # Numéro de version hors des en-têtes : renseignement gratuit pour un
          # scanner, aucun usage légitime côté client.
          serverTokens = false;

          # HSTS pour TOUS les vhosts, posée au niveau http et non dans
          # myLib.mkTlsVhost : un `add_header` de vhost REMPLACE la liste héritée,
          # donc le vhost Nextcloud — qui pose déjà la sienne, le module amont s'en
          # chargeant quand `https` est vrai — écrase celle-ci au lieu de l'émettre
          # en double. Les autres vhosts — le portail Authelia, et tout service
          # ajouté ensuite — en héritent, alors qu'ils n'en avaient aucune :
          # `recommendedTlsSettings` n'en pose pas.
          #
          # Sans `includeSubDomains` : ces noms couvriraient des sous-domaines qui
          # ne sont pas tous servis d'ici, et une directive trop large se paie
          # pendant un an, durée que le navigateur mémorise.
          commonHttpConfig = ''
            add_header Strict-Transport-Security "max-age=31536000" always;

            # ADRESSE RÉELLE DU CLIENT, utilisable par les applications derrière
            # nginx. Deux chemins arrivent ici et il faut les distinguer :
            #
            #   - LAN et VPN : la connexion TCP vient de l'appareil lui-même, donc
            #     `$remote_addr` est déjà la bonne adresse et rien ne la falsifie.
            #   - tunnel Cloudflare : la connexion vient de cloudflared en 127.0.0.1,
            #     et la seule source utilisable est l'en-tête `CF-Connecting-IP`, que
            #     l'edge de Cloudflare RÉÉCRIT à chaque requête.
            #
            # Pourquoi pas `X-Forwarded-For` pour le second cas : Cloudflare AJOUTE
            # l'adresse du client à la chaîne existante au lieu de la remplacer, donc
            # un appelant qui envoie son propre en-tête se place devant. C'est
            # exactement le trou que ces deux `map` referment côté Nextcloud.
            #
            # Deux `map` en cascade plutôt qu'une expression régulière avec capture :
            # le repli quand l'en-tête est absent doit être évident à lire, c'est lui
            # qui décide de ce qui se passe si cloudflared change de comportement.
            #
            # À NE PAS confondre avec ce qui décide des ACCÈS. Les règles `networks`
            # d'Authelia continuent de s'appuyer sur `$remote_addr` seul (cf.
            # modules/system/server/authelia) : une décision d'autorisation ne doit
            # dépendre d'aucun en-tête, fût-il réputé fiable.
            map $remote_addr $cf_client_ip {
              default     "";
              127.0.0.1   $http_cf_connecting_ip;
            }

            map $cf_client_ip $real_client_ip {
              default   $cf_client_ip;
              ""        $remote_addr;
            }

            # Journal du portail : sans ça, toute tentative venue d'internet est
            # consignée comme venant de 127.0.0.1 et une campagne de bourrage
            # d'identifiants n'est attribuable à personne.
            log_format cf_combined '$real_client_ip - $remote_user [$time_local] '
                                   '"$request" $status $body_bytes_sent '
                                   '"$http_referer" "$http_user_agent"';
          '';
        };

        security.acme = {
          acceptTerms = true;

          defaults = {
            email = cfg.acmeEmail;

            # DNS-01 et pas HTTP-01 : les noms servis ici ne sont joignables depuis
            # internet ni en direct (aucun port redirigé sur la box) ni via
            # Cloudflare (le nom interne est en nuage gris), donc Let's Encrypt ne
            # peut pas valider par une requête HTTP.
            #
            # PIÈGE : ce réglage ne suffit pas seul. Un vhost qui active enableACME
            # pose par défaut un `acmeRoot`, ce qui bascule ce certificat-là en
            # HTTP-01 et ignore ce dnsProvider — d'où myLib.mkTlsVhost.
            dnsProvider = "cloudflare";

            # credentialFiles plutôt que environmentFile : lego reçoit le jeton par
            # les credentials systemd. Réutilise le secret de cloudflare-cli.
            credentialFiles."CF_DNS_API_TOKEN_FILE" = config.sops.secrets."cloudflare/api_token".path;

            # Le résolveur du host est la box, qui répond depuis son cache : elle
            # continuerait d'annoncer l'ancien TXT et lego conclurait à tort que la
            # propagation a échoué.
            dnsResolver = "1.1.1.1:53";
          };
        };

        # Le jeton doit porter la permission Zone:DNS:Edit sur la zone concernée.
        sops.secrets."cloudflare/api_token" = { };

        # nginx doit pouvoir lire les certificats produits par acme.
        users.users.nginx.extraGroups = [ "acme" ];

        # 80 volontairement fermé : le challenge passe par le DNS, et les deux
        # chemins d'accès (tunnel en local, clients du LAN/VPN) attaquent
        # directement en TLS. L'ouvrir n'apporterait qu'une redirection.
        #
        # 443 ouvert sur les interfaces internes seulement (cf. le mkMerge en tête
        # de ce bloc). Le trafic public n'arrive pas par là mais par cloudflared,
        # qui parle à nginx sur la boucle locale, déjà de confiance.
      }
    ]
  );
}
