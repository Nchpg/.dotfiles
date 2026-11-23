{
  config,
  lib,
  pkgs-stable,
  pkgs-unstable,
  myLib,
  ...
}:

# Données Garmin Connect pour Claude : le serveur MCP de Taxuspt/garmin_mcp, en lecture seule. Public (claude.ai
# l'appelle depuis ses serveurs), fermé par un jeton tiré au premier démarrage dans le dossier d'état. Connexion
# au compte Garmin et adresse du connecteur : `sudo garmin-mcp-login`. Changer le jeton : supprimer
# /var/lib/garmin-mcp/token, relancer le service et recréer le connecteur.
let
  cfg = config.systemSettings.garminMcp;

  host = "${cfg.subdomain}.${config.systemSettings.proxy.domain}";

  python3Packages = pkgs-unstable.python3Packages;

  # garmin_mcp plafonne mcp sous 2.0 (API FastMCP renommée), nixpkgs est passé à 2.x.
  mcp = python3Packages.buildPythonPackage rec {
    pname = "mcp";
    version = "1.30.0";
    format = "wheel";
    src = python3Packages.fetchPypi {
      inherit pname version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-Zm7bUAlQPhBHydYDRqdW+UsmHwXMJiXyPUHHKP/EhNA=";
    };
    dependencies = with python3Packages; [
      anyio
      httpx
      httpx-sse
      jsonschema
      pydantic
      pydantic-settings
      pyjwt
      cryptography
      python-multipart
      sse-starlette
      starlette
      typing-extensions
      typing-inspection
      uvicorn
    ];
    pythonImportsCheck = [ "mcp.server.fastmcp" ];
  };

  # Révision auditée : en changer, c'est relire le diff (outils ajoutés, appels réseau, dépendances).
  package = python3Packages.buildPythonApplication {
    pname = "garmin-mcp";
    version = "0.1.0-unstable-2026-10-20";
    pyproject = true;
    src = pkgs-unstable.fetchFromGitHub {
      owner = "Taxuspt";
      repo = "garmin_mcp";
      rev = "a2ca5fcac34524b83814fe2fcf3d479f8a75983f";
      hash = "sha256-+feBYmZs6S+xt0YfelHTUQqql2qXHBy9krvNHBajCsc=";
    };
    build-system = [ python3Packages.hatchling ];
    dependencies = with python3Packages; [
      fitparse
      garminconnect
      mcp
      python-dotenv
      requests
    ];
    # Versions épinglées en amont (uv.lock) ; garminconnect suit ici nixpkgs, plus récent face aux changements
    # de connexion de Garmin.
    pythonRelaxDeps = true;
    postInstall = "install -Dm755 ${./serve.py} $out/bin/garmin-mcp-serve";
    nativeCheckInputs = with python3Packages; [
      pytestCheckHook
      pytest-asyncio
      pytest-mock
      pytest-timeout
    ];
    enabledTestPaths = [ "tests/unit" ];
    disabledTests = [
      # Relance un python nu, sans les dépendances : propre au bac à sable.
      "test_importing_the_package_has_no_credential_side_effects"
      # garminconnect plus récent : 401 et 429 lèvent leur exception propre, le message d'aide reste le même.
      "test_proxy_classifies_real_library_http_error_shape"
    ];
    meta.mainProgram = "garmin-mcp-serve";
  };

  state = "/var/lib/garmin-mcp";
  tokens = {
    GARMINTOKENS = "${state}/tokens";
    GARMINTOKENS_BASE64 = "${state}/tokens.b64";
  };

  # nginx (headers) : FastMCP n'accepte que l'hôte local (protection contre le DNS rebinding) ; réponses en flux
  # (SSE) ; un appel à Garmin peut prendre jusqu'à 90 s (GARMIN_MCP_CALL_TIMEOUT).
  proxyConfig = ''
    proxy_set_header Host 127.0.0.1:${toString cfg.port};
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_read_timeout 120s;
  '';

  login = pkgs-stable.writeShellApplication {
    name = "garmin-mcp-login";
    text = ''
      # Identifiants et code MFA demandés une fois ; Garmin ne les revoit plus, le service vit des jetons.
      systemd-run --pty --wait --collect --quiet \
        -p DynamicUser=yes -p StateDirectory=garmin-mcp -p UMask=0077 \
        ${lib.concatMapStringsSep " " (k: "-E ${k}=${tokens.${k}}") (lib.attrNames tokens)} \
        ${package}/bin/garmin-mcp-auth "$@"
      systemctl restart garmin-mcp
      echo
      echo "Adresse du connecteur (claude.ai, Réglages > Connecteurs > Ajouter un connecteur personnalisé) :"
      echo "https://${host}/$(cat ${state}/token)/mcp"
    '';
  };
in
{
  options.systemSettings.garminMcp = {
    enable = lib.mkEnableOption "le serveur MCP Garmin Connect, en lecture seule, pour Claude";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "garmin";
      description = "Sous-domaine public du serveur, sous `proxy.domain`.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8098;
      description = "Port de bouclage du serveur, derrière nginx.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.garminMcp exige le proxy.";
      }
    ];

    environment.systemPackages = [ login ];

    systemd.services.garmin-mcp = {
      description = "Serveur MCP Garmin Connect (lecture seule)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = tokens // {
        GARMIN_MCP_TRANSPORT = "streamable-http";
        GARMIN_MCP_PORT = toString cfg.port;
        # Sans sessions : claude.ai ne rouvre pas une session expirée.
        GARMIN_MCP_STATELESS_HTTP = "true";
      };
      serviceConfig = {
        ExecStart = lib.getExe package;
        DynamicUser = true;
        StateDirectory = "garmin-mcp";
        StateDirectoryMode = "0700";
        UMask = "0077";
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

    services.nginx.virtualHosts.${host} = myLib.server.mkTlsVhost {
      # Le jeton passe dans le chemin : aucun journal d'accès (ni fichier, ni onglet Trafic).
      extraConfig = "access_log off;";
      locations = {
        # claude.ai : le jeton du chemin devient l'en-tête que garmin-mcp vérifie.
        "~ ^/(?<token>[A-Za-z0-9_-]+)/mcp$" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          recommendedProxySettings = false;
          # `set` avant `rewrite`, dont l'expression régulière remplacerait les captures.
          extraConfig = proxyConfig + ''
            set $bearer "Bearer $token";
            rewrite ^ /mcp break;
            proxy_set_header Authorization $bearer;
          '';
        };
        # Clients qui posent l'en-tête eux-mêmes, et sondes (/healthz, /readyz).
        "/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          recommendedProxySettings = false;
          extraConfig = proxyConfig;
        };
      };
    };

    # /readyz : 503 tant que la connexion à Garmin n'est pas faite ou a échoué.
    systemSettings.proxy.sites.${host} = {
      public = true;
      lanShortcut = false;
      probes.garmin-mcp.path = "/readyz";
    };

    systemSettings.notify.discord.units = [ "garmin-mcp" ];
  };
}
