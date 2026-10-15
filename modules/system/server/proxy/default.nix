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

  static = config.systemSettings.network.staticIPv4;

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
  # Elle ne notifie rien elle-même : elle SORT EN ERREUR (cf. myLib.server.mkProbe).
  expiryCheckText = ''
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

  # Sondes déclarées par `sites`, à plat : nom de la cible -> définition.
  probes = lib.concatLists (
    lib.mapAttrsToList (
      host: site:
      lib.mapAttrsToList (name: probe: {
        inherit name;
        value = {
          url = "https://${host}${probe.path}";
          inherit (probe) module;
        };
      }) site.probes
    ) cfg.sites
  );
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

    sites = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        {
          "cloud.exemple.fr" = {
            public = true;
            probes.nextcloud-portail.module = "http_authelia";
          };
        }
      '';
      description = ''
        NOMS SERVIS par ce host, et ce que leur publication implique hors de
        nginx. Chaque module y déclare ses propres noms ; ce module en tire, en
        un seul endroit :

          - la route dans le tunnel Cloudflare (`cloudflared.ingress`) des noms
            `public` ;
          - la réécriture dnsmasq vers l'adresse du LAN (`dns.overrides`) des
            noms `lanShortcut` ;
          - les sondes blackbox (`monitoring.blackbox.targets`) de `probes`.

        Ces trois listes vivaient jusque-là chacune de leur côté, recopiées à la
        main dans le profil pour une partie des noms et posées par les modules
        pour d'autres : un nom ajouté à l'une manquait aux deux autres sans que
        rien ne le dise.

        Les VHOSTS nginx restent l'affaire de chaque module, qui seul sait ce
        qu'ils servent. Plusieurs modules peuvent décrire le même nom, leurs
        définitions fusionnent.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              public = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Publie le nom sur internet par le tunnel Cloudflare. Faux par
                  défaut : un nom n'est joignable que depuis le LAN et le VPN tant
                  qu'on ne l'a pas décidé, et l'absence de route est elle-même une
                  protection (cf. modules/system/server/vaultwarden).
                '';
              };

              upstream = lib.mkOption {
                type = lib.types.str;
                default = "https://127.0.0.1:443";
                description = ''
                  Service local vers lequel le tunnel envoie ce nom. nginx sur la
                  boucle locale, sauf exception : c'est lui qui porte le TLS et
                  le portail.
                '';
              };

              lanShortcut = lib.mkOption {
                type = lib.types.bool;
                default = config.public;
                defaultText = lib.literalExpression "public";
                description = ''
                  Fait répondre au résolveur local l'adresse du LAN pour ce nom
                  (et ses sous-domaines, syntaxe de dnsmasq). Sans ça, ouvrir
                  depuis le salon un nom publié fait sortir la requête jusqu'à
                  l'edge Cloudflare pour redescendre par le tunnel vers une
                  machine qui est sur le même commutateur, et une panne de box
                  suffit à le rendre injoignable sur place.

                  Commodité et non sécurité. Et c'est À ÉCARTER pour un nom
                  public dont une sonde doit vérifier le chemin COMPLET : la
                  réécriture vaut aussi pour ce host, donc la sonde taperait
                  nginx en direct et ne traverserait plus le tunnel.
                '';
              };

              probes = lib.mkOption {
                default = { };
                description = ''
                  Sondes blackbox sur ce nom, par nom de cible. Sans effet si
                  `systemSettings.monitoring` n'est pas activé.

                  Elles partent de CE host : un nom en `lanShortcut` est donc
                  sondé sur nginx en direct, sans traverser le tunnel.
                '';
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options = {
                      path = lib.mkOption {
                        type = lib.types.str;
                        default = "/";
                        description = "Chemin sondé, barre oblique initiale comprise.";
                      };

                      module = lib.mkOption {
                        type = lib.types.str;
                        default = "http_2xx";
                        description = "Module blackbox, cf. `monitoring.blackbox.targets`.";
                      };
                    };
                  }
                );
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.server.mkInternalPorts config { tcp = [ 443 ]; })

      (lib.mkIf cfg.expiryCheck.enable (
        myLib.server.mkProbe pkgs-stable {
          name = "acme-expiry-check";
          description = "Vérifie la date d'expiration des certificats servis";
          timerDescription = "Sonde quotidienne d'expiration des certificats";
          inherit (cfg.expiryCheck) interval;
          runtimeInputs = with pkgs-stable; [
            openssl
            coreutils
          ];
          text = expiryCheckText;

          # `after` et non `requires` : si nginx est arrêté, on VEUT que la
          # sonde tourne et échoue, c'est précisément l'un des cas qu'elle
          # existe pour attraper.
          after = [
            "nginx.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];

          serviceConfig = {
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
      ))

      # Publication des noms déclarés dans `sites` : route du tunnel,
      # raccourci du LAN et sondes, tirés d'une seule déclaration.
      {
        assertions = [
          {
            # listToAttrs garderait la première en silence, et l'autre sonde
            # disparaîtrait sans un mot.
            assertion = lib.length (lib.unique (map (p: p.name) probes)) == lib.length probes;
            message = "systemSettings.proxy.sites : deux sondes portent le même nom de cible (${
              lib.concatStringsSep ", " (map (p: p.name) probes)
            }).";
          }
          {
            assertion = lib.all (s: !s.lanShortcut) (lib.attrValues cfg.sites) || static != null;
            message = "systemSettings.proxy.sites : `lanShortcut` exige un adressage statique (systemSettings.network.staticIPv4), c'est l'adresse que le résolveur répond.";
          }
        ];

        systemSettings.cloudflared.ingress = lib.mapAttrs (_: site: site.upstream) (
          lib.filterAttrs (_: site: site.public) cfg.sites
        );

        systemSettings.dns.overrides = lib.mkIf (static != null) (
          lib.mapAttrs (_: _: static.address) (lib.filterAttrs (_: site: site.lanShortcut) cfg.sites)
        );

        systemSettings.monitoring.blackbox.targets = lib.mkIf config.systemSettings.monitoring.enable (
          lib.listToAttrs probes
        );
      }

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
        #
        # nginx aussi, qui casse HTTPS sans qu'aucun certificat soit en cause.
        # Une ligne, et elle couvre une panne que la sonde ne verrait qu'au
        # prochain passage quotidien.
        systemSettings.notify.discord.units =
          lib.concatMap (cert: [
            "acme-${cert}"
            "acme-order-renew-${cert}"
          ]) certNames
          ++ [ "nginx" ];
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
          # myLib.server.mkTlsVhost : un `add_header` de vhost REMPLACE la liste héritée,
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

            # 429 et non le 503 par défaut pour un refus de `limit_req` : le premier
            # dit « tu vas trop vite », le second « le service est en panne ». Posé
            # UNE fois ici pour tous les vhosts qui limitent (applications, partages
            # Nextcloud) : la directive ne tolère pas le doublon dans un contexte.
            limit_req_status 429;
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
            # HTTP-01 et ignore ce dnsProvider — d'où myLib.server.mkTlsVhost.
            dnsProvider = "cloudflare";

            # credentialFiles plutôt que environmentFile : lego reçoit le jeton par
            # les credentials systemd. Réutilise le secret de cloudflare-cli.
            credentialFiles."CF_DNS_API_TOKEN_FILE" = config.sops.secrets."cloudflare/api_token".path;

            # Le résolveur du host est la box, qui répond depuis son cache : elle
            # continuerait d'annoncer l'ancien TXT et lego conclurait à tort que la
            # propagation a échoué.
            dnsResolver = "1.1.1.1:53";

            # Sans ARI, lego n'envoie plus le champ `replaces`, que Let's Encrypt
            # refuse (403 « requester account did not request the certificate
            # being replaced ») pour un certificat émis par un AUTRE compte —
            # cas de tous ceux émis avant le passage de `acmeEmail` à null, qui a
            # changé de compte. Le renouvellement se cale alors sur la seule
            # expiration (`--dynamic`) : on perd les renouvellements anticipés
            # que Let's Encrypt demande via ARI lors d'une révocation de masse.
            extraLegoRenewFlags = [ "--ari-disable" ];
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
