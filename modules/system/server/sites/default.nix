{
  config,
  lib,
  myLib,
  ...
}:

# Sites web servis depuis une image de conteneur. Chaque site déclaré ici pose
# d'un coup son conteneur, son vhost nginx avec certificat et sa route dans le
# tunnel — les trois blocs étant toujours les mêmes, seul ce qui change reste à
# écrire.
#
# Aucun port n'est ouvert sur la box : les sites publics passent par le MÊME
# tunnel que le reste, qui route autant de noms qu'on veut.
let
  cfg = config.systemSettings.sites;

  names = lib.attrNames cfg;

  # Port de bouclage attribué automatiquement, pour n'avoir ni liste à tenir ni
  # collision à arbitrer. Il peut se DÉCALER quand un site s'insère avant un
  # autre dans l'ordre alphabétique : sans conséquence, conteneur et vhost étant
  # régénérés ensemble. Détail d'implémentation, jamais une adresse à
  # communiquer.
  basePort = 8080;
  portOf = lib.listToAttrs (lib.imap0 (i: n: lib.nameValuePair n (basePort + i)) names);
in
{
  options.systemSettings.sites = lib.mkOption {
    default = { };
    description = "Sites web servis depuis une image de conteneur.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            domain = lib.mkOption {
              type = lib.types.str;
              example = "monsite.exemple.fr";
              description = ''
                Nom servi. Sous `.lan.` pour un site qui ne doit pas sortir de la
                maison, à la racine du domaine sinon — cf. la convention de
                nommage du profil.
              '';
            };

            image = lib.mkOption {
              type = lib.types.str;
              example = "ghcr.io/moi/monsite:main";
              description = ''
                Image du conteneur.

                Un TAG mutable est attendu ici, contrairement au reste du dépôt :
                c'est ce qui permet à Watchtower de déployer une nouvelle version
                sans rebuild. L'arbitrage dépend du rôle — un site qu'on veut voir
                bouger tout seul d'un côté, l'accès VPN épinglé sur son empreinte
                de l'autre.
              '';
            };

            containerPort = lib.mkOption {
              type = lib.types.port;
              default = 80;
              description = "Port sur lequel l'image écoute, à l'intérieur du conteneur.";
            };

            public = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Publie le site sur internet par le tunnel. `false` le laisse
                joignable seulement depuis le LAN et le VPN, par son nom en
                `.lan.`, sans qu'aucune route ne l'expose.
              '';
            };

            autoUpdate = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Pose le label que Watchtower surveille.

                À laisser à `false` pour tout ce qui touche à l'accès ou aux
                secrets : Watchtower travaille par le socket Docker, dont l'accès
                équivaut à être root sur la machine. Lui confier un conteneur,
                c'est accepter que ce qui est poussé sur le registre s'exécute ici
                sans validation humaine — acceptable pour un site vitrine, pas
                pour une brique d'infrastructure.
              '';
            };

            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = ''
                Variables d'environnement. Rien de secret ici : leur valeur finit
                en clair dans le store, lisible par tous les utilisateurs de la
                machine et publiée avec le dépôt. Pour un secret, passer par
                `environmentFiles`.
              '';
            };

            environmentFiles = lib.mkOption {
              type = lib.types.listOf lib.types.path;
              default = [ ];
              example = lib.literalExpression ''[ config.sops.secrets."monsite/env".path ]'';
              description = "Fichiers d'environnement, pour les secrets (sops).";
            };

            volumes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Volumes, au format attendu par docker.";
            };
          };

          config.domain = lib.mkDefault name;
        }
      )
    );
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.sites exige systemSettings.proxy.enable : c'est lui qui porte nginx et l'obtention des certificats.";
      }
      {
        assertion = lib.all (s: !s.public) (lib.attrValues cfg) || config.systemSettings.cloudflared.enable;
        message = "systemSettings.sites : un site marqué `public` a besoin de systemSettings.cloudflared.enable pour être routé, aucun port n'étant ouvert sur la box.";
      }
    ];

    systemSettings.virtualisation.docker.enable = true;

    virtualisation.oci-containers.containers = lib.mapAttrs (name: site: {
      inherit (site)
        image
        volumes
        environmentFiles
        environment
        ;

      # Publication sur la BOUCLE LOCALE seulement : nginx est le seul à devoir
      # atteindre le conteneur, et c'est lui qui apporte le TLS. Un bind plus
      # large exposerait le site en clair sur le LAN, en contournant au passage
      # le pare-feu NixOS (docker insère ses règles en amont).
      ports = [ "127.0.0.1:${toString portOf.${name}}:${toString site.containerPort}" ];

      labels = lib.optionalAttrs site.autoUpdate {
        "com.centurylinklabs.watchtower.enable" = "true";
      };
    }) cfg;

    services.nginx.virtualHosts = lib.mapAttrs' (
      name: site:
      lib.nameValuePair site.domain (
        myLib.mkTlsVhost {
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString portOf.${name}}";
            proxyWebsockets = true;
          };
        }
      )
    ) cfg;

    # Une entrée par site public dans le tunnel déjà existant.
    systemSettings.cloudflared.ingress = lib.listToAttrs (
      map (site: lib.nameValuePair site.domain "https://127.0.0.1:443") (
        lib.filter (s: s.public) (lib.attrValues cfg)
      )
    );
  };
}
