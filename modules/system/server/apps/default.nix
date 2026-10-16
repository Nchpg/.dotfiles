{
  config,
  lib,
  ...
}:

let
  wireguard = config.systemSettings.vpn.wireguard;

  baseDomain = config.systemSettings.proxy.domain;

  peerAddress = lib.listToAttrs (map (p: lib.nameValuePair p.name "${p.address}/32") wireguard.peers);

  # Dérivé du nom, donc stable : ajouter une app ne renumérote pas les autres.
  # Plage sous les ports éphémères du noyau (32768+) et loin des services du host.
  hashedPort =
    name:
    20000 + lib.mod (lib.fromHexString (lib.substring 0 7 (builtins.hashString "sha256" name))) 10000;
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
            subdomain = lib.mkOption {
              type = lib.types.str;
              default = name;
              defaultText = lib.literalExpression "le nom de l'app";
              example = "etf";
              description = ''
                Sous-domaine servi, sous `proxy.domain` (et sous `vpn.` en `expose = "vpn"`).
                `"@"` : le domaine lui-même.
              '';
            };

            domain = lib.mkOption {
              type = lib.types.str;
              default =
                let
                  parent = if config.expose == "vpn" then "vpn.${baseDomain}" else baseDomain;
                in
                if baseDomain == null then
                  config.subdomain
                else if config.subdomain == "@" then
                  parent
                else
                  "${config.subdomain}.${parent}";
              defaultText = lib.literalExpression ''"<subdomain>.<proxy.domain>", ou "<subdomain>.vpn.<proxy.domain>" en vpn'';
              example = "monapp.exemple.fr";
              description = "Nom complet servi. Se déduit de `subdomain` ; à donner seulement hors de `proxy.domain`.";
            };

            expose = lib.mkOption {
              type = lib.types.enum [
                "public"
                "vpn"
                "sso"
              ];
              default = if config.public == false then "vpn" else "public";
              defaultText = lib.literalExpression ''"public"'';
              description = ''
                Qui atteint l'application :
                - `public` : tout internet, par le tunnel ;
                - `vpn` : mes appareils WireGuard seulement, sans route dans le tunnel
                  (nom sous `.vpn.`, que le joker DNS résout vers le tunnel WireGuard) ;
                - `sso` : internet par le tunnel, derrière le portail Authelia.
              '';
            };

            # Remplacée par `expose` ; gardée pour les déclarations du dépôt privé.
            public = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              visible = false;
              description = "Obsolète : `expose`.";
            };

            sso = {
              policy = lib.mkOption {
                type = lib.types.enum [
                  "one_factor"
                  "two_factor"
                ];
                default = "two_factor";
                description = "Politique Authelia de l'application (`expose = \"sso\"`).";
              };

              subject = lib.mkOption {
                type = lib.types.nullOr (lib.types.listOf lib.types.str);
                default = null;
                example = [ "user:nathan" ];
                description = ''
                  Comptes ou groupes Authelia admis (`null` : tout compte authentifié).
                '';
              };
            };

            devices = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = [
                "gram"
                "xiaomi_17t"
              ];
              description = ''
                Appareils admis en `expose = "vpn"`, par leur nom dans
                `vpn.wireguard.peers`. think lui-même est toujours admis (ses sondes).
              '';
            };

            allowedNetworks = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default =
                if config.devices == null then
                  null
                else
                  map (
                    d:
                    peerAddress.${d}
                      or (throw "systemSettings.apps.${name}.devices : « ${d} » n'est pas un peer de vpn.wireguard.peers (${toString (lib.attrNames peerAddress)}).")
                  ) config.devices
                  ++ lib.optional (wireguard.selfSource != null) wireguard.selfSource;
              defaultText = lib.literalExpression "les adresses des `devices`, plus celle de ce host";
              example = [ "10.8.0.2/32" ];
              description = ''
                Sources autorisées par nginx (notation `allow`), le reste reçoit
                403. `null` : aucun filtrage. Se déduit de `devices` d'ordinaire.
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
              example = 20085;
              description = ''
                Port de bouclage du point d'entrée. `null` : dérivé du nom (20000-29999).
                À fixer seulement si deux noms tombent sur le même port.
              '';
            };

            probe = lib.mkOption {
              default = { };
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
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = ''
                        Module blackbox, cf. `monitoring.blackbox.targets`. `null` :
                        `http_authelia` derrière le portail, `http_2xx` sinon.
                      '';
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
              default = if config.hostPort != null then config.hostPort else hashedPort name;
              description = "Port de bouclage retenu : `hostPort`, ou celui dérivé du nom.";
            };
          };
        }
      )
    );
  };
}
