{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

let
  cfg = config.systemSettings.authelia;
  inherit (cfg) port;

  mail = config.systemSettings.mail;

  instanceDir = "/var/lib/authelia-main";

  liveUsers = "${instanceDir}/users.yml";
  seedUsers = config.sops.secrets."authelia/users".path;

  # Le domaine lui-même ou un sous-domaine (hasSuffix seul accepterait `malexemple.fr`).
  isUnder = domain: host: host == domain || lib.hasSuffix ".${domain}" host;

  forwardedHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
  '';

  authzLocation = {
    proxyPass = "http://127.0.0.1:${toString cfg.port}/api/authz/auth-request";

    # La liste recommandée ajoute un second X-Forwarded-For, qu'Authelia lirait en premier.
    recommendedProxySettings = false;

    extraConfig = ''
      internal;
      # Sinon le point de contrôle s'interrogerait lui-même (auth_request est hérité).
      auth_request off;

      ${forwardedHeaders}
      proxy_set_header X-Original-Method $request_method;
      proxy_set_header X-Original-URL $scheme://$http_host$request_uri;

      # Base des règles `networks:` : $remote_addr n'est pas falsifiable.
      # Ne jamais le remplacer par $proxy_add_x_forwarded_for ni déclarer un
      # second X-Forwarded-For ici (nginx émet l'en-tête autant de fois).
      proxy_set_header X-Forwarded-For $remote_addr;

      # Sinon Authelia lit l'auth basique de l'application et répond 401.
      proxy_set_header Authorization "";

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
        Domaine porteur du cookie de session : parent commun du portail et des
        services protégés.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9091;
      description = "Port de bouclage d'Authelia (nginx uniquement).";
    };

    portalHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "auth.exemple.fr";
      description = "Nom du portail, à publier par le tunnel comme les services protégés.";
    };

    defaultRedirect = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://cloud.exemple.fr";
      description = ''
        Destination après authentification sans `rd` connu.
      '';
    };

    mutableUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Laisse Authelia réécrire son fichier d'utilisateurs ; sops ne sème que
        les comptes absents, et en retirer un ne le révoque plus.
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
      description = "Verbosité du journal. `trace` consigne les en-têtes d'authentification.";
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
        Règles de contrôle d'accès, la première qui correspond gagne. Défaut : `deny`.
      '';
    };

    nginxAuthRequest = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = {
        extraConfig = ''
          # Authelia décide d'après $request_uri (brute), nginx sert $uri (normalisée) :
          # un segment « .. » contournerait une règle `resources`.
          if ($request_uri ~* "(?:^|/|%2f)(?:\.|%2e){2}([/?]|%2f|\z)") {
            return 400;
          }

          auth_request /internal/authelia/authz;
          auth_request_set $redirection_url $upstream_http_location;
        '';
        locations."/internal/authelia/authz" = authzLocation;
      };
      defaultText = lib.literalExpression "le point de contrôle et sa directive auth_request";
      description = ''
        Socle à fusionner dans le vhost d'un service protégé : `auth_request` et
        le point de contrôle interne.
      '';
    };

    nginxProtect = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = {
        extraConfig = config.systemSettings.authelia.nginxAuthRequest.extraConfig + ''
          auth_request_set $auth_status $upstream_status;

          error_page 401 = @authelia_401;
          error_page 403 = @authelia_403;
        '';
        locations = config.systemSettings.authelia.nginxAuthRequest.locations // {
          "@authelia_401".extraConfig = ''
            internal;
            auth_request off;

            if ($redirection_url != "") {
              return 302 $redirection_url;
            }

            return 401;
          '';

          # Conditionné à $auth_status pour ne pas masquer un 403 applicatif.
          "@authelia_403".extraConfig = ''
            internal;
            auth_request off;
            default_type text/html;

            if ($auth_status = 403) {
              return 403 '${
                myLib.server.mkErrorPage {
                  title = "Accès refusé";
                  withLinks = true;
                  body = ''
                    <p>Ton compte est bien authentifié, mais il n&rsquo;est pas autorisé à
                    ouvrir ce service.</p>
                    <p>Si tu penses que c&rsquo;est une erreur, demande à
                    l&rsquo;administrateur.</p>
                    ${lib.optionalString (
                      cfg.portalHost != null
                    ) ''<p><a href="https://${cfg.portalHost}/logout">Se déconnecter et changer de compte</a></p>''}'';
                }
              }';
            }

            return 403;
          '';
        };
      };
      defaultText = lib.literalExpression "nginxAuthRequest, plus le traitement des refus 401 et 403";
      description = ''
        Fragment de vhost complet : le socle, la redirection vers le portail
        sur refus d'Authelia et une page pour le compte hors périmètre.
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
        assertion = cfg.domain == null || cfg.portalHost == null || isUnder cfg.domain cfg.portalHost;
        message = "systemSettings.authelia : portalHost doit être sous domain, sinon le cookie de session ne lui sera jamais envoyé.";
      }
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.authelia exige systemSettings.proxy.enable (nginx et le certificat du portail).";
      }
    ];

    # restartUnits : Authelia lit ces fichiers au démarrage seulement.
    sops.secrets =
      lib.genAttrs
        [
          "authelia/jwt_secret"
          "authelia/storage_key"
          "authelia/session_secret"
          "authelia/users"
        ]
        (_: {
          owner = "authelia-main";
          restartUnits = [
            "authelia-main.service"
          ]
          ++ lib.optional cfg.mutableUsers "authelia-seed-users.service";
        });

    services.redis.servers.authelia = {
      enable = true;
      port = 0;
      unixSocket = "/run/redis-authelia/redis.sock";
      unixSocketPerm = 660;
    };

    users.users.authelia-main.extraGroups = [
      "redis-authelia"
    ]
    ++ lib.optional mail.enable "smtp";

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
        live=${lib.escapeShellArg liveUsers}
        seed=${lib.escapeShellArg seedUsers}
      ''
      + builtins.readFile ./seed-users.sh;
    };

    services.authelia.instances.main = {
      enable = true;

      # Par fichier : la configuration finit dans le store.
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

          redis.host = config.services.redis.servers.authelia.unixSocket;

          expiration = "12h";
          inactivity = "2h";
          remember_me = "1M";
        };

        regulation = {
          max_retries = 3;
          find_time = "2m";
          ban_time = "10m";
        };

        storage.local.path = "${instanceDir}/db.sqlite3";

        notifier =
          if mail.enable then
            {
              smtp = {
                address = mail.url;
                username = mail.user;
                sender = "Authelia <${mail.from}>";
              };
            }
          else
            { filesystem.filename = "${instanceDir}/notification.txt"; };

        totp.issuer = cfg.domain;

        access_control = {
          default_policy = "deny";
          inherit (cfg) rules;
        };
      };
    };

    systemSettings.proxy.sites = lib.optionalAttrs (cfg.portalHost != null) {
      ${cfg.portalHost} = {
        public = true;
        probes.authelia.path = "/api/health";
      };
    };

    services.nginx.virtualHosts.${cfg.portalHost} = myLib.server.mkTlsVhost {
      # cloudflared se connecte depuis 127.0.0.1 : cf_combined journalise l'adresse réelle.
      extraConfig = ''
        access_log /var/log/nginx/access.log cf_combined;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";

        # La liste recommandée concatène le X-Forwarded-For du client, qu'Authelia lirait en premier.
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Connection "";
          ${forwardedHeaders}proxy_set_header X-Forwarded-For $remote_addr;
        '';
      };
    };
  };
}
