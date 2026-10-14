{
  config,
  lib,
  ...
}:

# Applications web servies depuis des images de conteneurs. Chaque application
# déclarée ici pose d'un coup ses conteneurs, son vhost nginx avec certificat et
# sa route dans le tunnel — les trois blocs étant toujours les mêmes, seul ce qui
# change reste à écrire.
#
# UNE APPLICATION, PLUSIEURS CONTENEURS. Le modèle est celui de compose et le
# reproduit fidèlement : les conteneurs d'une même application partagent un
# réseau dédié et s'y résolvent PAR LEUR NOM. Un `proxy_pass http://backend:8000`
# écrit pour compose fonctionne ici sans être touché.
#
# Ce qu'il fait de MIEUX que compose, et c'est la raison de ne pas se contenter
# de lancer le fichier d'origine : un seul conteneur est publié sur le host, sur
# la boucle locale, et c'est celui que nginx sert. Les autres n'exposent AUCUN
# port — ni sur le LAN, ni sur la boucle locale — et ne sont joignables que
# depuis le réseau de leur application. Un `ports: 8000:8000` de compose, lui,
# écoute sur toutes les interfaces de la machine et laisse n'importe qui du LAN
# court-circuiter nginx.
#
# Aucun port n'est ouvert sur la box : les applications publiques passent par le
# MÊME tunnel que le reste, qui route autant de noms qu'on veut.
#
# Le module est découpé par sujet : ce fichier porte les options d'une
# application, containers.nix les conteneurs et leur réseau, firewall.nix le
# pare-feu, nginx.nix le vhost et la publication, assertions.nix les garde-fous.
let
  cfg = config.systemSettings.apps;

  names = lib.attrNames cfg;

  # Ports de bouclage attribués aux applications qui n'en déclarent pas
  # (`hostPort`) : le premier libre à partir de `basePort`, dans l'ordre
  # alphabétique, en sautant ceux que d'autres ont réclamés.
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
              description = ''
                Nom servi. Sous `.lan.` pour une application qui ne doit pas
                sortir de la maison, à la racine du domaine sinon — cf. la
                convention de nommage du profil.
              '';
            };

            public = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Publie l'application sur internet par le tunnel. `false` la laisse
                joignable seulement depuis le LAN et le VPN, par son nom en
                `.lan.`, sans qu'aucune route ne l'expose.
              '';
            };

            allowedNetworks = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = [ "10.8.0.2/32" ];
              description = ''
                Sources autorisées par nginx, en notation `allow` : tout le
                reste reçoit un 403 avant d'atteindre l'application. `null` :
                aucun filtrage.

                Le montage du coffre (cf. modules/system/server/vaultwarden),
                pour une application qui ne doit sortir que par le tunnel
                WireGuard : un nom sous `vpn.` résolu vers 10.8.0.1, `public`
                à faux, et ici les adresses des appareils admis. C'est la
                barrière qui tient le jour où un nom se retrouve routé par
                mégarde — cloudflared arrive en 127.0.0.1, qui n'est pas dans
                la liste.

                Posé au niveau `server`, donc hérité par toutes les locations, y
                compris celles de la limitation de débit. Ne regarde que
                l'adresse de la connexion, jamais un en-tête.
              '';
            };

            internetAccess = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Laisse les conteneurs de l'application ouvrir des connexions vers
                internet — une API de cotations, un service tiers.

                Vers internet SEULEMENT : les plages privées, le tunnel et la
                boucle locale restent fermés, si bien qu'un conteneur compromis
                n'y gagne pas un pied sur le LAN. Le retour du trafic passe par
                la règle `established` du pare-feu, rien à ouvrir pour lui.

                Faux par défaut : une application qui n'a rien à chercher dehors
                doit échouer bruyamment le jour où elle essaie, plutôt que de
                disposer en silence d'un accès que personne ne lui a accordé.
              '';
            };

            entrypoint = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "frontend";
              description = ''
                Conteneur que nginx sert, et le SEUL qui soit publié — sur la
                boucle locale uniquement.

                `null` quand l'application n'a qu'un conteneur : le désigner
                serait une cérémonie sans objet, il est déduit. Une assertion le
                réclame dès qu'il y en a plusieurs.

                Tout ce qui arrive sur le domaine lui est transmis, y compris les
                chemins d'API : l'aiguillage interne reste l'affaire de
                l'application, comme sous compose. Ce module ne cherche pas à
                connaître sa structure.
              '';
            };

            proxyTimeout = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "180s";
              description = ''
                Délai au-delà duquel nginx abandonne une requête en attente de
                l'application. `null` garde le défaut de nginx, soit soixante
                secondes.

                À poser pour une application dont certaines requêtes CALCULENT —
                une simulation, un rendu, une inférence. Le symptôme sans ça est
                un 504 au bout d'une minute exactement, alors que l'application
                travaille encore et finirait par répondre.

                PLAFOND À CONNAÎTRE : Cloudflare coupe à cent secondes sur le
                plan gratuit, et ce n'est pas réglable. Au-delà, aucune valeur
                ici ne sauvera quoi que ce soit pour un visiteur venu par le
                tunnel — il faut rendre le traitement asynchrone côté
                application.
              '';
            };

            rateLimit = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Limite le débit de requêtes, PAR ADRESSE CLIENTE.

                  À activer dès qu'un chemin DÉCLENCHE DU CALCUL — une API qui
                  simule, qui rend une image, qui interroge un modèle. Exposé sans
                  limite, un chemin de ce genre est un robinet à processeur ouvert
                  sur internet : n'importe qui peut boucler dessus et saturer la
                  machine, ce qui emporterait tous les autres services avec.

                  Faux par défaut parce que servir des fichiers statiques ne coûte
                  rien, et qu'une limite posée sans raison finit par gêner un
                  usage légitime avant de gêner qui que ce soit d'autre.
                '';
              };

              paths = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "/api" ];
                description = ''
                  Chemins comptés, en préfixe — `/api` attrape aussi
                  `/api/quoi/que/ce/soit`.

                  Liste VIDE : c'est toute l'application qui est comptée, fichiers
                  statiques compris. Préférer désigner les chemins coûteux, pour
                  qu'un visiteur qui charge une page ne consomme pas le quota qui
                  protège l'API.
                '';
              };

              rate = lib.mkOption {
                type = lib.types.str;
                default = "60r/m";
                description = ''
                  Débit soutenu autorisé, au format de nginx.

                  Une requête par seconde en moyenne : très au-delà de ce qu'un
                  humain devant une interface produit, et cent fois en dessous de
                  ce qu'un script obtiendrait sans limite.
                '';
              };

              burst = lib.mkOption {
                type = lib.types.ints.positive;
                default = 20;
                description = ''
                  Requêtes acceptées d'un coup au-delà du débit, servies sans
                  délai puis décomptées.

                  Sans rafale, une interface qui émet trois appels au chargement
                  d'une page se ferait refuser les deux derniers. C'est ce réglage
                  qui distingue « limiter les abus » de « casser l'application ».
                '';
              };
            };

            hostPort = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              example = 8085;
              description = ''
                Port de BOUCLAGE sur lequel le point d'entrée est publié, et que
                nginx vise. Détail d'implémentation, jamais une adresse à
                communiquer.

                `null` en attribue un automatiquement : le premier libre à partir
                de 8080, dans l'ordre alphabétique des applications qui n'en
                déclarent pas. À ÉCRIRE pour une application installée à demeure :
                l'attribution automatique décale les ports dès qu'une application
                s'insère avant une autre dans l'ordre alphabétique, ce qui
                renumérote des conteneurs qui n'ont rien demandé. Une assertion
                refuse deux applications sur le même port.
              '';
            };

            probe = lib.mkOption {
              default = null;
              description = ''
                Sonde blackbox de l'application, nommée comme elle. `null` : aucune.

                Ça compte plus pour un conteneur que pour un service systemd : un
                service qui meurt se voit, un conteneur qui redémarre en boucle
                reste `active`, et un conteneur qui répond des erreurs ne se voit
                QUE d'une sonde.

                Le nom d'une application publique n'a PAS de réécriture dnsmasq
                (cf. `lanShortcut` dans `systemSettings.proxy.sites`) : la sonde
                sort jusqu'à l'edge Cloudflare et redescend par le tunnel, donc
                elle vérifie le chemin public complet. Viser un chemin qui ne
                CALCULE pas : une sonde qui consommerait le quota de
                `rateLimit` serait à l'envers.
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

            # ---------------------------------------------- valeurs dérivées
            #
            # En LECTURE SEULE et internes : des noms construits une fois ici et
            # lus par les autres fichiers de ce module (conteneurs, pare-feu,
            # nginx), plutôt que des fonctions recopiées dans chacun.

            # UN RÉSEAU PAR APPLICATION, même quand elle n'a qu'un conteneur.
            #
            # La version précédente ne le posait qu'à partir de deux, au motif qu'en
            # dessous « il n'y a personne à résoudre ». Le raisonnement oubliait ce qui
            # arrive à un conteneur sans `--network` : il rejoint le réseau PAR DÉFAUT de
            # podman, avec tous les autres qui sont dans le même cas. Deux applications
            # d'un seul conteneur se retrouvaient donc sur le même pont, libres de se
            # parler — l'inverse exact de ce que ce module annonce.
            #
            # Visible dans un `podman ps` : la colonne réseau du portfolio affichait
            # `podman`, le réseau partagé, pendant que ceux de rlkart affichaient le leur.
            #
            # Le coût d'un pont pour un conteneur seul est négligeable ; celui d'une
            # exception dans un raisonnement de cloisonnement ne l'est pas. Toutes les
            # applications sont désormais traitées pareil, ce qui supprime au passage la
            # distinction de cas dans six blocs.
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
                NOM DU PONT IMPOSÉ, au lieu du `podmanN` que netavark attribue
                dans l'ordre de création. C'est ce qui permet d'écrire des
                règles de pare-feu par APPLICATION plutôt qu'un joker `podman*`
                qui les mettrait toutes dans le même sac — cf. firewall.nix, où
                toute la sécurité de l'isolation repose sur ce nom.

                Quinze caractères maximum, limite du noyau pour un nom
                d'interface (IFNAMSIZ). Une assertion la vérifie plutôt que de
                laisser podman échouer au démarrage.
              '';
            };

            zone = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              # Un tiret est légal dans un nom d'attribut Nix, pas dans un
              # identifiant nginx. Le point n'est pas traité : une assertion
              # n'admet que lettres, chiffres, tirets et soulignés.
              default = "app_${lib.replaceStrings [ "-" ] [ "_" ] name}";
              description = "Zone `limit_req` de l'application.";
            };

            entrypointName = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              internal = true;
              # Le conteneur que nginx sert. Quand une application n'en a qu'un,
              # le désigner serait une cérémonie sans objet : on le déduit.
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
