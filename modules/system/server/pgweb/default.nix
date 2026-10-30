{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Visionneuse Postgres sur <subdomain>.vpn.<domaine> : le contenu des bases et leur activité
# (`pg_stat_activity`), les courbes restant dans Grafana. Le VPN (appareils qui ont le service
# « pgweb »), puis Authelia en 2FA, comme le dashboard.
let
  cfg = config.systemSettings.pgweb;
  authelia = config.systemSettings.authelia;
  wireguard = config.systemSettings.vpn.wireguard;

  host = "${cfg.subdomain}.vpn.${config.systemSettings.proxy.domain}";

  # Pair : le rôle porte le nom de l'utilisateur système du service, sans mot de passe.
  role = "pgweb";

  # Un favori par base : `--bookmarks-only` refuse toute autre connexion (pas d'adresse libre).
  bookmarks = pkgs-stable.linkFarm "pgweb-bookmarks" (
    map (db: {
      name = "${db}.toml";
      path = pkgs-stable.writeText "${db}.toml" ''
        url = "postgres:///${db}?host=/run/postgresql&user=${role}&sslmode=disable"
      '';
    }) cfg.databases
  );

  allowed =
    wireguard.sourcesFor "pgweb" ++ lib.optional (wireguard.selfSource != null) wireguard.selfSource;
in
{
  options.systemSettings.pgweb = {
    enable = lib.mkEnableOption "la visionneuse Postgres pgweb";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "pg";
      description = "Sous-domaine, sous `vpn.<proxy.domain>`.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8096;
      description = "Port de bouclage du service, derrière nginx.";
    };

    databases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.services.postgresql.ensureDatabases;
      defaultText = lib.literalExpression "services.postgresql.ensureDatabases";
      description = "Bases proposées à la connexion, une par favori.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemSettings.vpn.wireguard.services.pgweb = {
      label = "Postgres";
      inherit host;
    };
    systemSettings.authelia.services.pgweb = {
      label = "Postgres";
      inherit host;
    };

    assertions = [
      {
        assertion = config.services.postgresql.enable;
        message = "systemSettings.pgweb : aucun Postgres sur ce host (services.postgresql.enable).";
      }
      {
        assertion = authelia.enable && config.systemSettings.proxy.enable && wireguard.enable;
        message = "systemSettings.pgweb exige le VPN, le portail Authelia et le proxy : il ne doit jamais être servi sans connexion.";
      }
      {
        assertion = cfg.databases != [ ];
        message = "systemSettings.pgweb : aucune base à proposer (databases).";
      }
    ];

    services.postgresql.ensureUsers = [ { name = role; } ];

    # Le mode `--readonly` de pgweb filtre des mots-clés, contournable : c'est le rôle qui garantit
    # la lecture seule. `pg_monitor` : les requêtes des autres rôles dans l'onglet Activity.
    systemd.services.postgresql-setup.script = lib.mkAfter ''
      psql -tAc 'GRANT pg_read_all_data, pg_monitor TO "${role}"'
    '';

    systemd.services.pgweb = {
      description = "Visionneuse Postgres pgweb";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql-setup.service" ];
      requires = [ "postgresql-setup.service" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs-stable.pgweb)
          "--bind=127.0.0.1"
          "--listen=${toString cfg.port}"
          "--skip-open"
          "--sessions"
          "--bookmarks-only"
          "--bookmarks-dir=${bookmarks}"
          "--readonly"
          "--no-ssh"
        ];
        DynamicUser = true;
        User = role;
        Restart = "on-failure";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = [ "" ];
      };
    };

    services.nginx.virtualHosts.${host} = lib.mkMerge [
      (myLib.server.mkTlsVhost {
        extraConfig = myLib.server.nginxAllowOnly allowed;
        locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}";
      })
      authelia.nginxProtect
    ];

    systemSettings.authelia.rules = [ (authelia.ruleFor "pgweb") ];

    systemSettings.proxy.sites.${host} = {
      public = false;
      probes.pgweb.module = "http_authelia";
    };

    systemSettings.notify.discord.units = [ "pgweb" ];
  };
}
