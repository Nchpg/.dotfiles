{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.nextcloud;
  authelia = config.systemSettings.authelia;
  mail = config.systemSettings.mail;
  wireguard = config.systemSettings.vpn.wireguard;
  monitoring = config.systemSettings.monitoring;

  internalHost = if cfg.extraHostNames != [ ] then lib.head cfg.extraHostNames else null;

  nextcloudPackage =
    if cfg.publicSharing.enable && cfg.publicSharing.canonicalLinkWebUi then
      pkgs-stable.nextcloud33.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          export NC_SHARE_HOST=${cfg.hostName}
          total=0
          for f in $out/dist/*.js; do
            # `~` comme délimiteur : le motif contient des accolades.
            n=$(${pkgs-stable.perl}/bin/perl -0777 -i -pe '
              BEGIN{$c=0}
              $c += s~(["\x27]/s/\{token\}["\x27],\s*\{\s*token:\s*this\.share\.token\s*\}\s*,\s*\{\s*baseURL:\s*)[^}]*?(\s*\})~$1"https://$ENV{NC_SHARE_HOST}"$2~g;
              END{print STDERR $c}
            ' "$f" 2>&1 >/dev/null)
            total=$((total + n))
          done
          echo "canonical share-link (web UI) : $total remplacement(s)"
          # Au moins 2 remplacements attendus (un par bundle).
          if [ "$total" -lt 2 ]; then
            echo "ERREUR canonicalLinkWebUi : motif du lien de partage introuvable (attendu >=2, obtenu $total). Le bundle Nextcloud a changé de forme ; ajuster le motif." >&2
            exit 1
          fi
        '';
      })
    else
      pkgs-stable.nextcloud33;
in
{
  config = lib.mkIf cfg.enable {
    # Ouvert appareil par appareil (page VPN) : il se déclare au registre du VPN.
    systemSettings.vpn.wireguard.services = lib.mkIf wireguard.enable {
      nextcloud = {
        label = "Nextcloud";
        host = if internalHost != null then internalHost else cfg.hostName;
      };
    };
    # Et compte par compte (page Authelia) : le nom public, celui que garde le portail.
    systemSettings.authelia.services = lib.mkIf authelia.enable {
      nextcloud = {
        label = "Nextcloud";
        host = cfg.hostName;
      };
    };

    assertions = [
      {
        assertion = cfg.hostName != null;
        message = "systemSettings.nextcloud.hostName est requis : c'est le nom servi, et celui d'après lequel Nextcloud fabrique ses URL.";
      }
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.nextcloud exige systemSettings.proxy.enable : c'est lui qui porte nginx et l'obtention des certificats.";
      }
      {
        assertion = lib.intersectLists cfg.enabledApps cfg.disabledApps == [ ];
        message = "systemSettings.nextcloud : ${lib.concatStringsSep ", " (lib.intersectLists cfg.enabledApps cfg.disabledApps)} figure à la fois dans enabledApps et disabledApps.";
      }
      {
        # Les gardes sur null servent car toutes les assertions s'évaluent.
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

    # `mkBefore` : la première règle qui correspond gagne, et le `two_factor` sans
    # `networks` bloquerait les partages publics et les règles des autres services.
    systemSettings.authelia.rules = lib.mkBefore (
      lib.optionals authelia.enable (
        lib.optional cfg.publicSharing.enable {
          domain = cfg.hostName;
          policy = "bypass";
          resources = cfg.publicSharing.autheliaResources;
        }
        # Sans Authelia : les appareils VPN qui ont le service « nextcloud » ; les autres passent par
        # le second facteur comme tout le monde.
        ++ lib.optionals (wireguard.enable && wireguard.sourcesFor "nextcloud" != [ ]) (
          map
            (host: {
              domain = host;
              policy = "bypass";
              networks = wireguard.sourcesFor "nextcloud";
            })
            (
              # Le LAN n'est PAS dans les plages : tout appareil du WiFi sauterait le second facteur.
              [ cfg.hostName ] ++ cfg.extraHostNames
            )
        )
        ++ lib.optionals (internalHost != null && wireguard.selfSource != null) (
          # Le masquerade réécrit en adresse du LAN les paquets que ce host envoie à son
          # adresse de tunnel : la règle précédente ne s'applique pas à la sonde.
          lib.optional monitoring.enable {
            domain = internalHost;
            policy = "bypass";
            networks = [ wireguard.selfSource ];
            resources = [ "^/status\\.php$" ];
          }
          # `serverinfo` en dit bien plus que `status.php` : chemin exact, jamais un préfixe.
          ++ lib.optional (monitoring.apps.nextcloudTokenKey != null) {
            domain = internalHost;
            policy = "bypass";
            networks = [ wireguard.selfSource ];
            resources = [ "^/ocs/v2\\.php/apps/serverinfo/api/v1/info" ];
          }
        )
        # Les autres : les comptes qui ont le service (page Authelia), en 2FA.
        ++ [ (authelia.ruleFor "nextcloud") ]
      )
    );

    systemSettings.proxy.sites = {
      ${cfg.hostName} = {
        public = lib.mkDefault true;

        # Un 200 signifierait que le portail est tombé.
        probes = lib.optionalAttrs authelia.enable {
          nextcloud-portail.module = "http_authelia";
        };
      };
    }
    // lib.optionalAttrs (internalHost != null) {
      # Via le VPN (bypass) : seule sonde qui vérifie PHP et la base.
      ${internalHost}.probes.nextcloud.path = "/status.php";
    };

    services.nextcloud = {
      enable = true;
      # Majeure épinglée : les migrations de schéma sont irréversibles.
      package = nextcloudPackage;

      hostName = cfg.hostName;
      https = true;
      inherit (cfg) maxUploadSize;

      configureRedis = true;

      database.createLocally = true;

      phpOptions = {
        # Réclamés par la page d'état.
        "opcache.interned_strings_buffer" = lib.mkDefault "64";
        "opcache.memory_consumption" = lib.mkDefault "256";

        "opcache.validate_timestamps" = lib.mkDefault "0";
      };

      config = {
        dbtype = "pgsql";
        adminuser = cfg.adminUser;
        # Amorçage seulement ; accès perdu : sudo -u nextcloud nextcloud-occ user:resetpassword admin
        adminpassFile = config.sops.secrets."nextcloud/admin_pass".path;
      };

      settings = {
        trusted_domains = cfg.extraHostNames;
        trusted_proxies = [
          "127.0.0.1"
          "::1"
        ];

        overwriteprotocol = "https";

        # Boucle locale seulement (cloudflared) : ne pas élargir, le nom interne cesserait d'être navigable.
        overwritecondaddr = "^127\\.0\\.0\\.1$";

        # Effet de bord : `occ setupchecks` échoue en faux positif (redirection Authelia).
        "overwrite.cli.url" = "https://${cfg.hostName}";

        # Un `env[PATH]` sur le pool php-fpm est écrasé en silence par `phpEnv.PATH` de l'amont.
        preview_ffmpeg_path = "${pkgs-stable.ffmpeg-headless}/bin/ffmpeg";

        max_chunk_size = cfg.chunkSizeMiB * 1024 * 1024;

        default_phone_region = "FR";

        maintenance_window_start = 2;

        # Valeur système, et la chaîne "true" (comparaison stricte).
        twofactor_enforced = if cfg.enforceTwoFactor then "true" else "false";

        log_type = "file";

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
      // lib.optionalAttrs (cfg.language != null) (
        if cfg.forceLanguage then
          { force_language = cfg.language; }
        else
          { default_language = cfg.language; }
      )
      // lib.optionalAttrs (cfg.locale != null) (
        if cfg.forceLanguage then { force_locale = cfg.locale; } else { default_locale = cfg.locale; }
      )
      # Le mot de passe passe par `secretFile` : `settings` finit dans le store.
      // lib.optionalAttrs mail.enable {
        mail_smtpmode = "smtp";
        mail_smtphost = mail.host;
        mail_smtpport = mail.port;
        mail_smtpsecure = if mail.implicitTls then "ssl" else "tls";
        mail_smtpauth = true;
        mail_smtpname = mail.user;
        mail_from_address = lib.head (lib.splitString "@" cfg.mailFrom);
        mail_domain = lib.last (lib.splitString "@" cfg.mailFrom);
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

    sops.templates."nextcloud-secrets.json" = lib.mkIf mail.enable {
      owner = "nextcloud";
      content = builtins.toJSON {
        mail_smtppassword = config.sops.placeholder.${mail.passwordKey};
      };
    };

    # `random_page_cost` : 4 décrit un disque à plateaux.
    services.postgresql.settings = {
      shared_buffers = lib.mkDefault "2GB";
      effective_cache_size = lib.mkDefault "8GB";
      work_mem = lib.mkDefault "16MB";
      maintenance_work_mem = lib.mkDefault "512MB";
      random_page_cost = lib.mkDefault 1.1;
    };
  };
}
