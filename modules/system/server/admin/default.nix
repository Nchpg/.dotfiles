{
  config,
  options,
  lib,
  pkgs-stable,
  myLib,
  inputs,
  target,
  ...
}:

# Dashboard d'administration (onglet Sites) : lit l'état de think et des sites, et modifie
# apps.json par le seul workflow apps.yml. Il n'écrit nulle part ailleurs : pas de jeton
# d'écriture sur un dépôt, pas de root ; il peut seulement demander la recopie des données d'un
# environnement (admin-recopy). Derrière le VPN ET Authelia (cf. docs/apps.md).
let
  cfg = config.systemSettings.admin;
  images = config.systemSettings.appImages;
  authelia = config.systemSettings.authelia;
  wireguard = config.systemSettings.vpn.wireguard;

  host = "${cfg.subdomain}.vpn.${config.systemSettings.proxy.domain}";

  # Les appareils qui ont le service « admin » (vpn-peers.json, page VPN), et think lui-même.
  allowed =
    wireguard.sourcesFor "admin" ++ lib.optional (wireguard.selfSource != null) wireguard.selfSource;

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

  # Services de think qui ne viennent pas d'apps.json (cloud, coffre, métriques…) : montrés en
  # lecture seule sous les sites. Tirés de proxy.sites, où tout nom servi se déclare.
  # Authelia : repéré dans le vhost nginx (auth_request vers son point de contrôle).
  services =
    let
      appDomains = map (a: a.domain) (lib.attrValues config.systemSettings.apps);
      vhosts = config.services.nginx.virtualHosts;
      behindAuthelia =
        domain:
        let
          v = vhosts.${domain} or null;
          text =
            if v == null then
              ""
            else
              lib.concatStrings ([ v.extraConfig ] ++ map (l: l.extraConfig) (lib.attrValues v.locations));
        in
        lib.hasInfix "auth_request /internal/authelia" text;
    in
    lib.mapAttrsToList (domain: site: {
      inherit domain;
      # Public : déclaré tel, ou routé par le tunnel Cloudflare par son propre module (Grafana).
      public = site.public || config.systemSettings.cloudflared.ingress ? ${domain};
      name = lib.head (lib.attrNames site.probes ++ [ domain ]);
      probed = site.probes != { };
      authelia = behindAuthelia domain;
    }) (lib.filterAttrs (domain: _: !lib.elem domain appDomains) config.systemSettings.proxy.sites);

  # Page VPN : paramètres du tunnel (pour la config d'un nouvel appareil) et appareils connus ;
  # `added` : inscrit par le dashboard (vpn-peers.json), les autres viennent de vpn.nix.
  addedPeers =
    if wireguard.peersFile == null then [ ] else lib.attrNames (lib.importJSON wireguard.peersFile);
  vpnInfo = {
    endpoint = "${toString wireguard.host}:${toString wireguard.port}";
    inherit (wireguard)
      dns
      allowedIPs
      subnet
      serverAddress
      ;
    peers = map (p: {
      inherit (p)
        name
        address
        publicKey
        services
        ;
      added = lib.elem p.name addedPeers;
    }) wireguard.peers;
    # Services ouverts appareil par appareil : le registre que chaque module remplit.
    services = lib.mapAttrsToList (name: s: {
      inherit name;
      inherit (s) label host;
    }) wireguard.services;
  };

  # Page Authelia : services ouverts compte par compte (registre du portail), et ce que la
  # génération active donne à chaque compte (main se lit dans authelia-accounts.json).
  autheliaInfo = {
    services = lib.mapAttrsToList (name: s: {
      inherit name;
      inherit (s) label host;
    }) authelia.services;
    accounts = lib.mapAttrs (_: a: a.services) authelia.accounts;
    # Page « Ajouter un compte » : le secret à éditer et le portail (mot de passe oublié).
    inherit (authelia) usersSecret portalHost;
  };

  # Page SSH : clés autorisées de chaque compte (publiques), et pour en ajouter une : le port, une
  # adresse de think dans le tunnel, et les fichiers du dépôt qui déclarent les comptes.
  sshInfo = {
    users = lib.mapAttrsToList (name: keys: { inherit name keys; }) (
      lib.filterAttrs (_: keys: keys != [ ]) config.systemSettings.ssh.authorizedKeys
    );
    # Celles de keysFile se retirent d'ici (les autres sont dans le code Nix).
    fileKeys =
      if config.systemSettings.ssh.keysFile == null then
        { }
      else
        lib.importJSON config.systemSettings.ssh.keysFile;
    inherit (config.systemSettings.ssh) port;
    host = if wireguard.enable then wireguard.serverAddress else target.host;
    files = map (
      d:
      let
        rel = lib.removePrefix "${toString inputs.self}/" (toString d.file);
      in
      if lib.hasSuffix ".nix" rel then rel else "${rel}/default.nix"
    ) options.systemSettings.users.definitionsWithLocations;
  };

  # Page Comptes : résumé des comptes Authelia, sans aucun secret (le fichier d'utilisateurs et la
  # base sont à root). Une table absente (autre version d'Authelia) donne une liste vide.
  accountsSummary = pkgs-stable.writeShellApplication {
    name = "admin-accounts";
    runtimeInputs = [
      pkgs-stable.yq-go
      pkgs-stable.sqlite
      pkgs-stable.jq
      pkgs-stable.coreutils
    ];
    text = ''
      dir=/var/lib/authelia-main
      out="$STATE_DIRECTORY/accounts.json"
      users=$(yq -o=json '.users // {} | to_entries | map({"name": .key, "displayName": (.value.displayname // ""), "email": (.value.email // ""), "groups": (.value.groups // []), "disabled": (.value.disabled // false)})' "$dir/users.yml" 2> /dev/null || echo '[]')
      q() { sqlite3 -readonly -json "$dir/db.sqlite3" "$1" 2> /dev/null | grep . || echo '[]'; }
      totp=$(q "SELECT username FROM totp_configurations")
      keys=$(q "SELECT username, COUNT(*) AS n FROM webauthn_credentials GROUP BY username")
      last=$(q "SELECT username, MAX(time) AS time FROM authentication_logs WHERE successful = 1 GROUP BY username")
      fails=$(q "SELECT username, COUNT(*) AS n FROM authentication_logs WHERE successful = 0 AND time > datetime('now', '-1 day') GROUP BY username")
      jq -n --argjson u "$users" --argjson t "$totp" --argjson k "$keys" --argjson l "$last" --argjson f "$fails" '
        $u | map(. as $x | . + {
          totp: ([$t[] | select(.username == $x.name)] | length > 0),
          securityKeys: ([$k[] | select(.username == $x.name) | .n] | add // 0),
          lastLogin: ([$l[] | select(.username == $x.name) | .time] | first // null),
          failures24h: ([$f[] | select(.username == $x.name) | .n] | add // 0)
        })' > "$out.new"
      chmod 644 "$out.new"
      mv -f "$out.new" "$out"
    '';
  };

  # Onglet Trafic : les sessions et applis connectées de Nextcloud et Vaultwarden, et les essais
  # ratés de Nextcloud, lus dans leurs bases (root) ; résumé sans aucun jeton.
  nextcloud = config.systemSettings.nextcloud;
  vaultwarden = config.systemSettings.vaultwarden;
  trafficSummary = pkgs-stable.writeShellApplication {
    name = "admin-traffic";
    runtimeInputs = [
      pkgs-stable.sqlite
      pkgs-stable.jq
      pkgs-stable.coreutils
      pkgs-stable.util-linux
      config.services.postgresql.package
    ];
    text = ''
      out="$STATE_DIRECTORY/traffic.json"
      result='{}'
    ''
    + lib.optionalString nextcloud.enable ''
      # type 0 : session d'un navigateur ; 1 : appli (mot de passe d'appli, client de synchro).
      nc() {
        runuser -u ${config.services.nextcloud.config.dbuser} -- psql -h ${config.services.nextcloud.config.dbhost} \
          -d ${config.services.nextcloud.config.dbname} -tAq -c "SELECT coalesce(json_agg(t), '[]') FROM ($1) t" 2> /dev/null | grep . || echo '[]'
      }
      tokens=$(nc "SELECT uid AS \"user\", name, type, last_activity AS last FROM oc_authtoken ORDER BY last_activity DESC")
      failures=$(nc "SELECT ip, action, occurred AS at, metadata FROM oc_bruteforce_attempts WHERE occurred > extract(epoch FROM now()) - 31 * 86400 ORDER BY occurred DESC LIMIT 500")
      result=$(jq -n --argjson r "$result" --argjson t "$tokens" --argjson f "$failures" \
        --argjson d '${builtins.toJSON ([ nextcloud.hostName ] ++ nextcloud.extraHostNames)}' \
        '$r + {nextcloud: {domains: $d, tokens: $t, failures: ($f | map(.metadata |= (try fromjson catch {})))}}')
    ''
    + lib.optionalString vaultwarden.enable ''
      db=/var/lib/${config.systemd.services.vaultwarden.serviceConfig.StateDirectory}/db.sqlite3
      devices=$(sqlite3 -readonly -json "$db" "SELECT u.name AS user, u.email AS email, d.name AS name, d.atype AS type, d.created_at AS created, d.updated_at AS updated FROM devices d JOIN users u ON u.uuid = d.user_uuid ORDER BY d.updated_at DESC" 2> /dev/null | grep . || echo '[]')
      result=$(jq -n --argjson r "$result" --argjson v "$devices" --argjson d '${
        builtins.toJSON [ vaultwarden.hostName ]
      }' \
        '$r + {vaultwarden: {domains: $d, unit: "vaultwarden.service", devices: $v}}')
    ''
    + ''
      jq -n --argjson r "$result" '$r + {updated: now | floor}' > "$out.new"
      chmod 644 "$out.new"
      mv -f "$out.new" "$out"
    '';
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
  };

  config = lib.mkIf cfg.enable {
    # Ouvert appareil par appareil (page VPN) : il se déclare au registre du VPN.
    systemSettings.vpn.wireguard.services.admin = {
      label = "Dashboard admin";
      inherit host;
    };
    # Et compte par compte (page Authelia), au registre du portail.
    systemSettings.authelia.services.admin = {
      label = "Dashboard admin";
      inherit host;
    };

    assertions = [
      {
        assertion = wireguard.sourcesFor "admin" != [ ];
        message = "systemSettings.admin : aucun appareil VPN n'a le service « admin » (vpn-peers.json) : plus personne n'ouvrirait le dashboard.";
      }
      {
        assertion = lib.any (a: lib.elem "admin" a.services) (lib.attrValues authelia.accounts);
        message = "systemSettings.admin : aucun compte Authelia n'a le service « admin » (authelia-accounts.json) : plus personne n'ouvrirait le dashboard.";
      }
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
        # QR code de la config d'un nouvel appareil VPN.
        pkgs-stable.qrencode
      ];
      environment = {
        ADMIN_LISTEN = "127.0.0.1:${toString cfg.port}";
        ADMIN_HOST = host;
        ADMIN_REPO = images.deploy.repository;
        ADMIN_BRANCH = images.deploy.branch;
        ADMIN_TARGET = target.name;
        ADMIN_MACHINE = target.host;
        ADMIN_DOMAIN = config.systemSettings.proxy.domain;
        ADMIN_REGISTRY = images.registry;
        ADMIN_REGISTRY_USER = images.login.username;
        ADMIN_PROMETHEUS = "http://127.0.0.1:${toString config.systemSettings.monitoring.internal.ports.prometheus}";
        # Journal de sshd (page SSH : connexions par clé, tentatives refusées), vide sans monitoring.
        ADMIN_LOKI = lib.optionalString config.systemSettings.monitoring.enable "http://127.0.0.1:${toString config.systemSettings.monitoring.internal.ports.loki}";
        ADMIN_LOGS_RETENTION = config.systemSettings.monitoring.logs.retention;
        ADMIN_SSH_UNIT = "sshd.service";
        ADMIN_DEPLOY_STATUS = "/var/lib/apps-deploy/status.json";
        ADMIN_HTMX = htmx;
        ADMIN_FONTS = "${pkgs-stable.geist-font}/share/fonts/truetype";
        ADMIN_PEERS_FILE = pkgs-stable.writeText "admin-peers.json" (
          builtins.toJSON (map (p: p.name) wireguard.peers)
        );
        ADMIN_SECRETS_FILE = pkgs-stable.writeText "admin-secrets.json" (builtins.toJSON secretKeys);
        ADMIN_SERVICES_FILE = pkgs-stable.writeText "admin-services.json" (builtins.toJSON services);
        ADMIN_RECOPY_STATUS = "/var/lib/admin-recopy";
        ADMIN_VPN_FILE = pkgs-stable.writeText "admin-vpn.json" (builtins.toJSON vpnInfo);
        ADMIN_SSH_FILE = pkgs-stable.writeText "admin-ssh.json" (builtins.toJSON sshInfo);
        ADMIN_ACCOUNTS_FILE = "/var/lib/admin-accounts/accounts.json";
        ADMIN_TRAFFIC_FILE = "/var/lib/admin-traffic/traffic.json";
        ADMIN_AUTHELIA_FILE = pkgs-stable.writeText "admin-authelia.json" (builtins.toJSON autheliaInfo);
        ADMIN_WG_PUBKEY = "/run/admin/wg-server.pub";
        # Tableau de bord système de Grafana, affiché dans la page Métriques (vide sans monitoring).
        ADMIN_METRICS_URL = lib.optionalString config.systemSettings.monitoring.enable "https://${config.systemSettings.monitoring.grafana.hostName}/d/${target.host}-systeme/systeme?orgId=1&from=now-6h&to=now&timezone=browser&var-gravite=error&var-gravite=warn&var-unite=$__all&var-contient=&refresh=1m";
      };
      serviceConfig = {
        ExecStart = lib.getExe package;
        # Clé publique du serveur WireGuard (pour la config d'un nouvel appareil), dérivée en root de
        # sa clé privée, que le dashboard ne lit jamais.
        ExecStartPre = lib.optional wireguard.enable "+${pkgs-stable.writeShellScript "admin-wg-pubkey" ''
          ${pkgs-stable.wireguard-tools}/bin/wg pubkey < ${
            config.sops.secrets.${wireguard.privateKeyKey}.path
          } > /run/admin/wg-server.pub
          chmod 444 /run/admin/wg-server.pub
        ''}";
        RuntimeDirectory = "admin";
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

    systemd.services.admin-accounts = lib.mkIf config.systemSettings.authelia.enable {
      description = "Résumé des comptes Authelia pour le dashboard (sans secret)";
      after = [ "authelia-main.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe accountsSummary;
        StateDirectory = "admin-accounts";
        StateDirectoryMode = "0755";
      };
    };
    systemd.timers.admin-accounts = lib.mkIf config.systemSettings.authelia.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };

    systemd.services.admin-traffic = lib.mkIf (nextcloud.enable || vaultwarden.enable) {
      description = "Applis et sessions de Nextcloud et Vaultwarden pour le dashboard (sans jeton)";
      after = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe trafficSummary;
        StateDirectory = "admin-traffic";
        StateDirectoryMode = "0755";
      };
    };
    systemd.timers.admin-traffic = lib.mkIf (nextcloud.enable || vaultwarden.enable) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };

    # « Recopier » : le dashboard (sans droits) dépose `<app>.want`, avec les dossiers à recopier (un
    # par ligne ; vide : tous). Root ne traite qu'un environnement en données « copie » connu de la
    # config, ne garde de la demande que les dossiers que la config lui donne (elle ne fait que
    # filtrer), et écrit son résultat dans son propre dossier (pas de lien piégé à suivre).
    systemd.paths.admin-recopy = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathExistsGlob = "/var/lib/private/admin/recopy/*.want";
    };

    systemd.services.admin-recopy = {
      description = "Recopie des données d'un environnement depuis son parent";
      path = [
        pkgs-stable.jq
        pkgs-stable.coreutils
        config.systemd.package
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "admin-recopy";
        StateDirectoryMode = "0755";
      };
      script = ''
        map=${pkgs-stable.writeText "admin-copies.json" (builtins.toJSON images.copies)}
        status_dir=$STATE_DIRECTORY
        shopt -s nullglob dotglob
        for want in /var/lib/private/admin/recopy/*.want; do
          app=$(basename "$want" .want)
          # Un fichier ordinaire seulement : un lien ne serait pas suivi.
          wanted=""
          if [ -f "$want" ] && [ ! -L "$want" ]; then
            wanted=$(head -c 8192 -- "$want")
          fi
          rm -f -- "$want"
          if ! [[ "$app" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || ! jq -e --arg a "$app" 'has($a)' "$map" > /dev/null; then
            echo "demande ignorée : $app n'est pas un environnement en données « copie »" >&2
            continue
          fi
          # Les paires de la config, réduites aux dossiers demandés (aucun : toutes).
          pairs=$(jq -c --arg a "$app" --arg w "$wanted" '($w | split("\n") | map(select(. != ""))) as $want
            | [.[$a].pairs[] | select(($want | length) == 0 or (.to | IN($want[])))]' "$map")
          if [ "$(jq length <<< "$pairs")" = 0 ]; then
            echo "demande ignorée : aucun dossier en copie de $app ne correspond" >&2
            continue
          fi
          write() {
            jq -n --arg s "$1" --arg d "$2" --argjson p "$pairs" '{state: $s, detail: $d, at: (now | floor), paths: [$p[].to]}' > "$status_dir/$app.json.tmp"
            mv "$status_dir/$app.json.tmp" "$status_dir/$app.json"
          }
          write "running" ""
          mapfile -t units < <(jq -r --arg a "$app" '.[$a].units[]' "$map")
          ok=1
          # Arrêt en échec : les données sont peut-être ouvertes, on n'y touche pas.
          systemctl stop "''${units[@]}" || ok=0
          while [ "$ok" = 1 ] && IFS=$'\t' read -r from to; do
            rm -rf --one-file-system -- "$to"
            mkdir -p "$(dirname "$to")"
            if [ -e "$from" ]; then
              cp -a -- "$from" "$to" || ok=0
            else
              mkdir -p "$to"
            fi
          done < <(jq -r '.[] | [.from, .to] | @tsv' <<< "$pairs")
          systemctl start "''${units[@]}" || ok=0
          if [ "$ok" = 1 ]; then
            write "done" ""
          else
            write "failed" "journalctl -u admin-recopy"
          fi
        done
      '';
    };

    # Appareils choisis, puis le portail : les deux, toujours.
    services.nginx.virtualHosts.${host} = myLib.server.mkTlsVhost {
      locations = {
        "/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          # Le compte connecté, pour que la page Authelia ne le laisse pas se fermer le dashboard.
          # Un niveau qui déclare un `auth_request_set` remplace la liste du parent : recopiés.
          extraConfig = ''
            auth_request_set $redirection_url $upstream_http_location;
            auth_request_set $auth_status $upstream_status;
            auth_request_set $authelia_user $upstream_http_remote_user;
            proxy_set_header Remote-User $authelia_user;
          '';
        };
      }
      // authelia.nginxProtect.locations;
      extraConfig = ''
        ${myLib.server.nginxAllowOnly allowed}
      ''
      + authelia.nginxProtect.extraConfig;
    };

    systemSettings.authelia.rules = [
      # Manifeste et icônes de l'application installée : le navigateur les lit parfois sans le cookie
      # de session. Rien de privé dedans, et nginx exige toujours le VPN.
      {
        domain = host;
        policy = "bypass";
        resources = [
          "^/manifest\\.webmanifest$"
          "^/static/(icon-[0-9]+|apple-touch-icon)\\.png$"
        ];
      }
      (authelia.ruleFor "admin")
    ];

    systemSettings.proxy.sites.${host} = {
      public = false;
      probes.admin.module = "http_authelia";
    };

    systemSettings.notify.discord.units = [ "admin" ];
  };
}
