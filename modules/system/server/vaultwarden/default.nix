{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Garder la version à jour : des clients plus récents que le serveur affichent un coffre vide sans erreur.
let
  cfg = config.systemSettings.vaultwarden;
  mail = config.systemSettings.mail;
  wireguard = config.systemSettings.vpn.wireguard;

  port = 8222;

  proxyPass = "http://127.0.0.1:${toString port}";

  dataDir = "/var/lib/${
    if lib.versionOlder config.system.stateVersion "24.11" then "bitwarden_rs" else "vaultwarden"
  }";

  kdfCheckText = ''
    db=${dataDir}/db.sqlite3

    if [ ! -r "$db" ]; then
      echo "base introuvable ou illisible : $db" >&2
      exit 1
    fi

    # coalesce : la mémoire vaut NULL en PBKDF2 et `NULL < 64` n'est pas vrai.
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
        Nom servi, sous `vpn.` : enregistrement A public « DNS only » vers l'adresse du serveur dans le tunnel.
      '';
    };

    allowedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Les appareils qui ont le service « vaultwarden » (vpn-peers.json, page VPN), et think.
      default =
        lib.optionals wireguard.enable (wireguard.sourcesFor "vaultwarden")
        ++ lib.optional (wireguard.selfSource != null) wireguard.selfSource;
      defaultText = lib.literalExpression "vpn.wireguard.sourcesFor \"vaultwarden\" ++ [ vpn.wireguard.selfSource ]";
      example = [ "10.8.0.0/24" ];
      description = ''
        Sources autorisées par nginx (notation `allow`), le reste reçoit 403.
        Le LAN en est exclu ; `selfSource` sert à la sonde seule.
      '';
    };

    signups.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Autorise la création de compte.
      '';
    };

    signups.domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "exemple.fr" ];
      description = "Domaines de courriel acceptés à l'inscription (vide : aucune restriction).";
    };

    admin.tokenKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "vaultwarden/admin_token";
      description = ''
        Clé sops du jeton du panneau `/admin`. `null` : panneau désactivé.
      '';
    };

    webVault = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sert l'interface web (JavaScript servi par ce serveur : à réserver au dépannage).
      '';
    };

    requireDeviceEmail = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Exige un code par courriel sur un appareil inconnu ; une panne du relais enfermerait dehors.
      '';
    };

    orgCreation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Autorise la création d'organisations.
      '';
    };

    trashRetentionDays = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 30;
      description = "Jours avant purge définitive de la corbeille. `null` : jamais.";
    };

    kdfCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Sonde vérifiant que tous les comptes dérivent leur clé en Argon2id au-dessus d'un plancher.
        '';
      };

      minMemory = lib.mkOption {
        type = lib.types.ints.positive;
        default = 64;
        description = "Mémoire minimale en Mio (défaut Bitwarden).";
      };

      minIterations = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Nombre de passes minimal (défaut Bitwarden).";
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
        Répertoire de la copie nocturne du module amont (même disque). `null` la coupe.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Ouvert appareil par appareil (page VPN) : il se déclare au registre du VPN.
      (lib.mkIf wireguard.enable {
        systemSettings.vpn.wireguard.services.vaultwarden = {
          label = "Vaultwarden";
          host = cfg.hostName;
        };
      })
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

          dbBackend = "sqlite";

          inherit (cfg) backupDir;

          # Identifiant WebAuthn : une clé enrôlée sous un nom ne marche pas sous un autre.
          domain = cfg.hostName;

          environmentFile = lib.optional needsEnvFile config.sops.templates."vaultwarden.env".path;

          config = {
            # IPv6 coupée sur le parc.
            ROCKET_ADDRESS = "127.0.0.1";
            ROCKET_PORT = port;

            ENABLE_WEBSOCKET = true;

            SIGNUPS_ALLOWED = cfg.signups.enable;
            SIGNUPS_DOMAINS_WHITELIST = lib.concatStringsSep "," cfg.signups.domains;

            SIGNUPS_VERIFY = false;

            SHOW_PASSWORD_HINT = false;

            WEB_VAULT_ENABLED = cfg.webVault;
            REQUIRE_DEVICE_EMAIL = cfg.requireDeviceEmail;

            ORG_CREATION_USERS = if cfg.orgCreation then "all" else "none";

            TRASH_AUTO_DELETE_DAYS = cfg.trashRetentionDays;

            DISABLE_2FA_REMEMBER = true;

            # Exige une horloge synchronisée.
            AUTHENTICATOR_DISABLE_TIME_DRIFT = true;

            # Le téléchargement d'icônes révèle à des tiers la liste des sites du coffre.
            DISABLE_ICON_DOWNLOAD = true;

            # Anti-SSRF vers 127.0.0.1 et le LAN (pas le défaut amont).
            HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS = true;

            EMERGENCY_ACCESS_ALLOWED = false;
            EMAIL_CHANGE_ALLOWED = false;
          }
          // lib.optionalAttrs mail.enable {
            SMTP_HOST = mail.host;
            SMTP_PORT = mail.port;
            SMTP_SECURITY = if mail.implicitTls then "force_tls" else "starttls";
            SMTP_USERNAME = mail.user;
            SMTP_FROM = mail.from;
            SMTP_FROM_NAME = "Coffre-fort";
          };
        };

        # EnvironmentFile systemd : `CLÉ=valeur` sans guillemets.
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

        services.nginx.virtualHosts.${cfg.hostName} = myLib.server.mkTlsVhost {
          extraConfig = ''
            ${myLib.server.nginxAllowOnly cfg.allowedNetworks}

            client_max_body_size 128M;
          '';

          locations = {
            "/".proxyPass = proxyPass;

            # access_log coupé : le jeton passe dans l'URL (?access_token=...).
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
          // lib.optionalAttrs (cfg.admin.tokenKey == null) {
            "^~ /admin".extraConfig = "return 404;";
          };
        };

        systemSettings.proxy.sites.${cfg.hostName}.probes.vaultwarden.path = "/alive";

        systemSettings.notify.discord.units = [
          "vaultwarden"
        ]
        ++ lib.optional (cfg.backupDir != null) "backup-vaultwarden";

        # Ne corrige que les copies à venir : chmod 0600 une fois sur l'existante.
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

          # `after` et non `requires` : la sonde lit un fichier, elle doit tourner service arrêté.
          after = [ "vaultwarden.service" ];

          serviceConfig = {
            User = "vaultwarden";
            Group = "vaultwarden";

            # En mode WAL, un lecteur SQLite doit écrire le fichier -shm.
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
