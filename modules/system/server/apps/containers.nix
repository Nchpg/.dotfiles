{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.apps;

  podmanBin = lib.getExe' config.virtualisation.podman.package "podman";

  unitOf = key: "podman-${key}";

  containerKey = appName: containerName: "${appName}-${containerName}";

  images = config.systemSettings.appImages.helpers;

  allContainers = lib.concatLists (
    lib.mapAttrsToList (
      appName: app:
      lib.mapAttrsToList (containerName: container: {
        key = containerKey appName containerName;
        inherit
          appName
          app
          containerName
          container
          ;
        isEntrypoint = containerName == app.entrypointName;

        image = images.image container.image;
        port = if container.port != null then container.port else images.port container.image;
        login = images.login container.image;
      }) app.containers
    ) cfg
  );

  registryOf = image: lib.head (lib.splitString "/" image);

  containerOptions = {
    image = lib.mkOption {
      type = lib.types.str;
      example = "portfolio";
      description = ''
        Nom court (`portfolio`, préfixé par `appImages.registry`), référence avec tag
        (`docker.io/library/postgres:17`), toutes deux épinglées par le lock, ou
        référence `@sha256:…` complète.
      '';
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8000;
      description = ''
        Port d'écoute dans le conteneur ; publié pour le seul point d'entrée.
        `null` : celui que l'image déclare (`EXPOSE`, relevé dans le lock).
        Sous 1024, `CAP_NET_BIND_SERVICE` en est déduite.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Variables d'environnement, en clair dans le store (secrets : `environmentFiles`).";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression ''[ config.sops.secrets."monapp/env".path ]'';
      description = "Fichiers d'environnement, pour les secrets (sops).";
    };

    cmd = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--workers"
        "4"
      ];
      description = "Remplace la commande de l'image (`command:` de compose). Vide : celle de l'image.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "1000:1000";
      description = ''
        Utilisateur du conteneur (`uid[:gid]`). `null` : celui de l'image.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2g";
      description = ''
        Plafond de mémoire (format podman). `null` : aucun.
      '';
    };

    pidsLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = "Plafond de processus.";
    };

    capabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "CHOWN"
        "SETUID"
        "SETGID"
      ];
      description = ''
        Capacités rendues au conteneur après le retrait de toutes.
      '';
    };

    dependsOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "backend" ];
      description = ''
        Conteneurs de la même application à démarrer avant celui-ci.
      '';
    };

    healthcheck = {
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "curl -fsS http://localhost:8000/health";
        description = ''
          Commande de sonde exécutée dans le conteneur (shell). `null` : aucune.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Intervalle entre deux exécutions de la sonde.";
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "5s";
        description = "Délai au-delà duquel une exécution de la sonde compte comme un échec.";
      };

      retries = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Échecs consécutifs avant que le conteneur soit déclaré malade.";
      };

      startPeriod = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Durée de grâce au démarrage pendant laquelle un échec ne compte pas.";
      };
    };

    volumes = lib.mkOption {
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            source = "donnees";
            target = "/var/lib/postgresql/data";
            readOnly = false;
          }
        ]
      '';
      description = ''
        Montages. Un `source` sans barre oblique initiale est un volume nommé podman.
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              example = "donnees";
              description = "Nom d'un volume géré par podman, ou chemin absolu sur le host.";
            };

            target = lib.mkOption {
              type = lib.types.str;
              example = "/var/lib/postgresql/data";
              description = "Chemin de montage à l'intérieur du conteneur, absolu.";
            };

            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Monte en lecture seule.";
            };
          };
        }
      );
    };
  };
in
{
  options.systemSettings.apps = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options = {
            containers = lib.mkOption {
              description = ''
                Conteneurs de l'application, sur un réseau propre à celle-ci. Le nom
                (`frontend`, `api`…) nomme l'unité `podman-<app>-<nom>` et sert de nom
                d'hôte aux autres conteneurs de l'app.
              '';
              type = lib.types.attrsOf (lib.types.submodule { options = containerOptions; });
            };

            container = lib.mkOption {
              default = null;
              description = ''
                Raccourci d'une app à un seul conteneur, qui devient `containers.web`.
              '';
              type = lib.types.nullOr (lib.types.submodule { options = containerOptions; });
            };
          };

          config.containers = lib.mkIf (config.container != null) { web = config.container; };
        }
      )
    );
  };

  config = lib.mkIf (cfg != { }) {
    sops.secrets = lib.listToAttrs (
      map (c: lib.nameValuePair c.login.passwordKey { }) (lib.filter (c: c.login != null) allContainers)
    );

    # Explicite : le défaut amont dépend de system.stateVersion.
    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers = lib.listToAttrs (
      map (
        c:
        lib.nameValuePair c.key {
          inherit (c) image;
          inherit (c.container) environmentFiles environment;

          volumes = map (
            v: "${v.source}:${v.target}${lib.optionalString v.readOnly ":ro"}"
          ) c.container.volumes;

          podman.sdnotify = if c.container.healthcheck.command != null then "healthy" else "conmon";

          # Boucle locale seulement : un bind plus large contournerait le pare-feu NixOS.
          ports = lib.optional c.isEntrypoint "127.0.0.1:${toString c.app.hostPortEffective}:${toString c.port}";

          networks = lib.singleton c.app.network;

          dependsOn = map (n: containerKey c.appName n) c.container.dependsOn;

          inherit (c.container) cmd user;

          login = lib.mkIf (c.login != null) {
            registry = registryOf c.image;
            inherit (c.login) username;
            passwordFile = config.sops.secrets.${c.login.passwordKey}.path;
          };

          extraOptions = [
            "--cap-drop=ALL"

            "--security-opt=no-new-privileges"

            "--pids-limit=${toString c.container.pidsLimit}"
          ]
          ++ lib.optional (c.container.memory != null) "--memory=${c.container.memory}"
          ++ lib.optional (c.port != null && c.port < 1024) "--cap-add=NET_BIND_SERVICE"

          ++ map (cap: "--cap-add=${cap}") c.container.capabilities

          ++ lib.optionals (c.container.healthcheck.command != null) [
            "--health-cmd=${c.container.healthcheck.command}"
            "--health-interval=${c.container.healthcheck.interval}"
            "--health-timeout=${c.container.healthcheck.timeout}"
            "--health-retries=${toString c.container.healthcheck.retries}"
            "--health-start-period=${c.container.healthcheck.startPeriod}"
          ]
          ++ lib.singleton "--network-alias=${c.containerName}";
        }
      ) allContainers
    );

    # `network exists` ne voit pas qu'un réseau ancien garde son ancien pont.
    systemd.services = lib.mkMerge (
      (lib.mapAttrsToList (appName: app: {
        ${app.networkUnit} = {
          description = "Réseau des conteneurs de ${appName}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          # `isolate=true` : netavark ne bloque le trafic inter-réseaux que sur demande.
          script =
            let
              net = lib.escapeShellArg app.network;
              bridge = lib.escapeShellArg app.bridge;
              opts = lib.escapeShellArgs [
                "--opt"
                "com.docker.network.bridge.name=${app.bridge}"
                "--opt"
                "isolate=true"
              ];
            in
            ''
              create() {
                ${podmanBin} network create ${opts} ${net}
              }

              if ! ${podmanBin} network exists ${net}; then
                create
                exit 0
              fi

              actual=$(${podmanBin} network inspect ${net} --format '{{.NetworkInterface}}' 2> /dev/null || true)

              if [ "$actual" != ${bridge} ]; then
                echo "réseau ${app.network} : pont « $actual » au lieu de « ${app.bridge} », recréation" >&2
                ${podmanBin} network rm -f ${net}
                create
              fi
            '';
        };
      }) cfg)

      ++ (map (c: {
        ${unitOf c.key} = {
          after = [ "${c.app.networkUnit}.service" ];
          requires = [ "${c.app.networkUnit}.service" ];
          partOf = [ "${c.app.networkUnit}.service" ];
        };
      }) allContainers)

      # À 100 ms (défaut), la limite de démarrage est atteinte en une demi-seconde.
      ++ (map (c: { ${unitOf c.key}.serviceConfig.RestartSec = "10s"; }) allContainers)

      # oci-containers pose `0` (aucun délai) à la même priorité : sans override, l'évaluation échoue.
      # Assez long pour une base qui initialise ses données, borné pour qu'une sonde jamais verte finisse en échec.
      ++ (map (
        c:
        lib.optionalAttrs (c.container.healthcheck.command != null) {
          ${unitOf c.key}.serviceConfig.TimeoutStartSec = lib.mkOverride 90 "5min";
        }
      ) allContainers)
    );
  };
}
