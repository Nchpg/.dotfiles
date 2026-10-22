{
  config,
  lib,
  pkgs-stable,
  myLib,
  inputs,
  target,
  ...
}:

# Dashboard d'administration (onglet Sites) : lit l'état de think et des sites, et modifie
# apps.json par le seul workflow apps.yml. Il n'écrit nulle part ailleurs : pas de jeton
# d'écriture sur un dépôt, pas de root. Derrière le VPN ET Authelia (cf. docs/apps.md).
let
  cfg = config.systemSettings.admin;
  images = config.systemSettings.appImages;
  authelia = config.systemSettings.authelia;
  wireguard = config.systemSettings.vpn.wireguard;

  host = "${cfg.subdomain}.vpn.${config.systemSettings.proxy.domain}";

  peerAddress = lib.listToAttrs (map (p: lib.nameValuePair p.name "${p.address}/32") wireguard.peers);
  allowed =
    map (
      d:
      peerAddress.${d}
        or (throw "systemSettings.admin.devices : « ${d} » n'est pas un peer de vpn.wireguard.peers.")
    ) cfg.devices
    ++ lib.optional (wireguard.selfSource != null) wireguard.selfSource;

  package = pkgs-stable.buildGoModule {
    pname = "admin";
    version = "0.1.0";
    src = ./app;
    vendorHash = null;
    env.CGO_ENABLED = "0";
    meta.mainProgram = "admin";
  };

  htmx = pkgs-stable.fetchurl {
    url = "https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js";
    hash = "sha256-4gndpcgjVHnzFm3vx3UOHbzVpcGAi3eS/C5nM3aPtEc=";
  };

  # Noms des secrets disponibles (jamais leur valeur) : la page propose ceux rangés sous un site.
  secretKeys =
    let
      walk =
        dir: prefix:
        lib.concatLists (
          lib.mapAttrsToList (
            n: type:
            if type == "directory" then
              walk "${dir}/${n}" "${prefix}${n}/"
            else
              lib.optional (
                lib.hasSuffix ".yaml" n && !lib.hasPrefix "." n
              ) "${prefix}${lib.removeSuffix ".yaml" n}"
          ) (builtins.readDir dir)
        );
    in
    walk "${inputs.secrets}" "";
in
{
  options.systemSettings.admin = {
    enable = lib.mkEnableOption "le dashboard d'administration (sites)";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Sous-domaine, sous `vpn.<proxy.domain>`.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8095;
      description = "Port de bouclage du service, derrière nginx.";
    };

    devices = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      example = [ "gram" ];
      description = "Appareils WireGuard admis (noms de vpn.wireguard.peers). think l'est toujours.";
    };

    subject = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "user:nathan" ];
      description = "Comptes Authelia admis, en 2FA.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = authelia.enable && config.systemSettings.proxy.enable;
        message = "systemSettings.admin exige le portail Authelia et le proxy : il ne doit jamais être servi sans connexion.";
      }
      {
        assertion = images.appsFile != null && images.watch.enable && images.login != null;
        message = "systemSettings.admin lit apps.json (appImages.appsFile) et utilise les jetons d'appImages.watch et appImages.login.";
      }
    ];

    systemd.services.admin = {
      description = "Dashboard d'administration de think";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # git (clone d'évaluation, ls-remote), nix (évaluation), systemctl (état d'apps-deploy).
      path = [
        pkgs-stable.git
        config.nix.package
        config.systemd.package
      ];
      environment = {
        ADMIN_LISTEN = "127.0.0.1:${toString cfg.port}";
        ADMIN_HOST = host;
        ADMIN_REPO = images.deploy.repository;
        ADMIN_BRANCH = images.deploy.branch;
        ADMIN_TARGET = target.name;
        ADMIN_DOMAIN = config.systemSettings.proxy.domain;
        ADMIN_REGISTRY = images.registry;
        ADMIN_REGISTRY_USER = images.login.username;
        ADMIN_PROMETHEUS = "http://127.0.0.1:${toString config.systemSettings.monitoring.internal.ports.prometheus}";
        ADMIN_DEPLOY_STATUS = "/var/lib/apps-deploy/status.json";
        ADMIN_HTMX = htmx;
        ADMIN_FONTS = "${pkgs-stable.geist-font}/share/fonts/truetype";
        ADMIN_PEERS_FILE = pkgs-stable.writeText "admin-peers.json" (
          builtins.toJSON (map (p: p.name) wireguard.peers)
        );
        ADMIN_SECRETS_FILE = pkgs-stable.writeText "admin-secrets.json" (builtins.toJSON secretKeys);
      };
      serviceConfig = {
        ExecStart = lib.getExe package;
        Restart = "on-failure";
        DynamicUser = true;
        StateDirectory = "admin";
        LoadCredential = [
          "dispatch:${config.sops.secrets.${images.watch.tokenKey}.path}"
          "ghcr:${config.sops.secrets.${images.login.passwordKey}.path}"
          # Jeton du dépôt de secrets, pour évaluer la config comme le fait `rebuild`.
          "nix-access:/var/lib/nix/access-tokens.conf"
        ];
        # Une évaluation de la config entière tient en quelques Go.
        MemoryMax = "4G";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    # Appareils choisis, puis le portail : les deux, toujours.
    services.nginx.virtualHosts.${host} = myLib.server.mkTlsVhost {
      locations = {
        "/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
        };
      }
      // authelia.nginxProtect.locations;
      extraConfig = ''
        ${myLib.server.nginxAllowOnly allowed}
      ''
      + authelia.nginxProtect.extraConfig;
    };

    systemSettings.authelia.rules = [
      {
        domain = host;
        policy = "two_factor";
        inherit (cfg) subject;
      }
    ];

    systemSettings.proxy.sites.${host} = {
      public = false;
      probes.admin.module = "http_authelia";
    };

    systemSettings.notify.discord.units = [ "admin" ];
  };
}
