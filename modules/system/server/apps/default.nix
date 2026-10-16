{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.apps;

  names = lib.attrNames cfg;

  basePort = 8080;
  explicitPorts = lib.filter (p: p != null) (map (a: a.hostPort) (lib.attrValues cfg));
  firstFree = p: if lib.elem p explicitPorts then firstFree (p + 1) else p;
  autoPorts =
    (lib.foldl'
      (
        acc: n:
        let
          p = firstFree acc.next;
        in
        {
          next = p + 1;
          ports = acc.ports // {
            ${n} = p;
          };
        }
      )
      {
        next = basePort;
        ports = { };
      }
      (lib.filter (n: cfg.${n}.hostPort == null) names)
    ).ports;
in
{
  options.systemSettings.apps = lib.mkOption {
    default = { };
    description = "Applications web servies depuis des images de conteneurs.";
    example = lib.literalExpression ''
      {
        monapp = {
          domain = "monapp.exemple.fr";
          entrypoint = "frontend";
          containers = {
            frontend = { image = "ghcr.io/moi/front@sha256:…"; port = 80; };
            backend = { image = "ghcr.io/moi/api@sha256:…"; };
          };
          rateLimit.paths = [ "/api" ];
        };
      }
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {
          options = {
            domain = lib.mkOption {
              type = lib.types.str;
              example = "monapp.exemple.fr";
              description = "Nom servi. Sous `.lan.` pour une application qui ne doit pas sortir de la maison.";
            };

            public = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Publie l'application par le tunnel. `false` : LAN et VPN seulement, sans route.";
            };

            allowedNetworks = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = [ "10.8.0.2/32" ];
              description = ''
                Sources autorisées par nginx (notation `allow`), le reste reçoit
                403. `null` : aucun filtrage.
              '';
            };

            internetAccess = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Laisse les conteneurs ouvrir des connexions vers internet seulement.
              '';
            };

            entrypoint = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "frontend";
              description = ''
                Conteneur que nginx sert. `null` s'il n'y en a qu'un.
              '';
            };

            proxyTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "180s";
              description = ''
                Délai d'attente nginx sur l'application (`null` : 60 s). Cloudflare coupe à 100 s.
              '';
            };

            rateLimit = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Limite le débit par adresse cliente.
                '';
              };

              paths = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "/api" ];
                description = ''
                  Chemins comptés, en préfixe. Liste vide : toute l'application.
                '';
              };

              rate = lib.mkOption {
                type = lib.types.str;
                default = "60r/m";
                description = "Débit soutenu autorisé, au format nginx.";
              };

              burst = lib.mkOption {
                type = lib.types.ints.positive;
                default = 20;
                description = "Requêtes acceptées d'un coup au-delà du débit.";
              };
            };

            hostPort = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              example = 8085;
              description = ''
                Port de bouclage du point d'entrée. `null` : le premier libre à
                partir de 8080, dans l'ordre alphabétique.
              '';
            };

            probe = lib.mkOption {
              default = null;
              description = ''
                Sonde blackbox de l'application, nommée comme elle (`null` : aucune).
              '';
              type = lib.types.nullOr (
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

            network = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              default = "app-${name}";
              description = "Réseau podman de l'application.";
            };

            networkUnit = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              default = "podman-network-${name}";
              description = "Unité systemd qui crée ce réseau.";
            };

            bridge = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              default = "br-${name}";
              description = ''
                Nom du pont imposé, pour les règles de pare-feu par application.
              '';
            };

            zone = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              default = "app_${lib.replaceStrings [ "-" ] [ "_" ] name}";
              description = "Zone `limit_req` de l'application.";
            };

            entrypointName = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              default =
                if config.entrypoint != null then config.entrypoint else lib.head (lib.attrNames config.containers);
              description = "Conteneur servi par nginx, déclaré ou déduit.";
            };

            hostPortEffective = lib.mkOption {
              type = lib.types.port;
              readOnly = true;
              internal = true;
              default = if config.hostPort != null then config.hostPort else autoPorts.${name};
              description = "Port de bouclage retenu : `hostPort`, ou celui attribué automatiquement.";
            };
          };

          config.domain = lib.mkDefault name;
        }
      )
    );
  };
}
