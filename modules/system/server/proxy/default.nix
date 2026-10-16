{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.proxy;

  static = config.systemSettings.network.staticIPv4;

  certNames = lib.attrNames config.security.acme.certs;

  # Lit l'expiration du certificat réellement servi : le onFailure des unités ACME ne voit pas un rechargement manqué.
  expiryCheckText = ''
    minDays=${toString cfg.expiryCheck.minDays}
    now=$(date +%s)
    limit=$((now + minDays * 86400))
    status=0

    for host in ${lib.concatStringsSep " " certNames}; do
      # </dev/null et timeout : s_client attendrait sinon indéfiniment.
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
        Contact du compte ACME, facultatif. Ce dépôt est public : préférer une adresse de rôle.
      '';
    };

    expiryCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Sonde sur la date d'expiration du certificat servi par nginx.";
      };

      minDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 21;
        description = ''
          Seuil d'alerte en jours restants (lego renouvelle à 30 jours).
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
        Noms servis par ce host, d'où sont tirés la route du tunnel, la
        réécriture dnsmasq et les sondes blackbox.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              public = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Publie le nom par le tunnel Cloudflare (sinon LAN et VPN seulement).";
              };

              upstream = lib.mkOption {
                type = lib.types.str;
                default = "https://127.0.0.1:443";
                description = "Service local vers lequel le tunnel envoie ce nom.";
              };

              lanShortcut = lib.mkOption {
                type = lib.types.bool;
                default = config.public;
                defaultText = lib.literalExpression "public";
                description = ''
                  Fait répondre l'adresse du LAN par le résolveur local pour ce nom.
                '';
              };

              probes = lib.mkOption {
                default = { };
                description = ''
                  Sondes blackbox sur ce nom, par nom de cible. Elles partent de ce host :
                  un nom en `lanShortcut` est sondé sur nginx directement.
                '';
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options = {
                      path = lib.mkOption {
                        type = lib.types.str;
                        default = "/";
                        description = "Chemin sondé.";
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

          # `after` et non `requires` : nginx arrêté doit faire échouer la sonde.
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

      {
        assertions = [
          {
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
        warnings = lib.optional (!config.systemSettings.notify.discord.enable) ''
          systemSettings.proxy : aucune surveillance du renouvellement ACME sur ce host.
          Les avis d'expiration de Let's Encrypt ont cessé le 4 juin 2025, et lego réessaie
          en silence pendant les trente jours qui précèdent l'expiration — la panne se
          découvre donc quand les navigateurs refusent la connexion.
          Active systemSettings.notify.discord.
        '';

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
          serverTokens = false;

          # Au niveau http : un add_header de vhost remplace la liste héritée.
          commonHttpConfig = ''
            add_header Strict-Transport-Security "max-age=31536000" always;

            # Journalisation et limites seulement, jamais les décisions d'accès :
            # pas X-Forwarded-For, que le client peut préfixer.
            map $remote_addr $cf_client_ip {
              default     "";
              127.0.0.1   $http_cf_connecting_ip;
            }

            map $cf_client_ip $real_client_ip {
              default   $cf_client_ip;
              ""        $remote_addr;
            }

            log_format cf_combined '$real_client_ip - $remote_user [$time_local] '
                                   '"$request" $status $body_bytes_sent '
                                   '"$http_referer" "$http_user_agent"';

            # Posé ici une fois (doublon interdit).
            limit_req_status 429;
          '';
        };

        security.acme = {
          acceptTerms = true;

          defaults = {
            email = cfg.acmeEmail;

            # Piège : un vhost avec enableACME pose un acmeRoot qui bascule en HTTP-01.
            dnsProvider = "cloudflare";

            credentialFiles."CF_DNS_API_TOKEN_FILE" = config.sops.secrets."cloudflare/api_token".path;

            # La box répond depuis son cache et ferait échouer la propagation.
            dnsResolver = "1.1.1.1:53";

            # Let's Encrypt refuse `replaces` (403) pour un certificat émis par un autre compte.
            extraLegoRenewFlags = [ "--ari-disable" ];
          };
        };

        sops.secrets."cloudflare/api_token" = { };

        users.users.nginx.extraGroups = [ "acme" ];
      }
    ]
  );
}
