{
  config,
  lib,
  target,
  ...
}:

let
  cfg = config.systemSettings.network;
  static = cfg.staticIPv4;
  hostName = target.machine; # profil-host, cf. lib/target-name.nix
in
{
  options = {
    systemSettings.network.staticIPv4 = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              description = "Adresse IPv4 fixe, sans le préfixe.";
              example = "192.168.1.32";
            };

            prefixLength = lib.mkOption {
              type = lib.types.ints.between 1 32;
              default = 24;
              description = "Longueur du préfixe du sous-réseau.";
            };

            gateway = lib.mkOption {
              type = lib.types.str;
              description = "Passerelle par défaut.";
              example = "192.168.1.254";
            };

            interface = lib.mkOption {
              type = lib.types.str;
              default = "en*";
              description = ''
                Motif `Match.Name` (systemd.network) de l'interface à
                configurer. Le défaut `en*` couvre l'ethernet quel que soit le
                nom que l'udev de la machine lui donne (enp2s0f0, eno1…) : un
                profil vaut pour tous les hosts, il ne doit pas dépendre du
                matériel de l'un d'eux.
              '';
            };

            nameservers = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Serveurs DNS. Liste vide = la passerelle.";
            };
          };
        }
      );
      default = null;
      description = ''
        Adressage IPv4 statique. `null` (défaut) = NetworkManager en DHCP,
        le cas des postes de travail.

        Renseigné, ce host bascule aussi sur le pare-feu nftables et ses ports
        s'ouvrent par INTERFACE — cf. `internalIifnames` juste en dessous.

        Renseigné, l'adresse est posée par systemd-networkd et NetworkManager
        est COUPÉ. Sur une machine administrée à distance, l'adresse est le
        seul moyen d'y accéder : elle doit être montée au boot par une unité
        déterministe, pas par un démon dont l'état persiste sur disque et
        dérive au premier `nmcli` tapé à la main.

        Corollaire : les modules qui pilotent NetworkManager (le picker WiFi
        de sway) deviennent inutilisables sur un tel host — ils l'assertent
        déjà de leur côté.
      '';
    };

    systemSettings.network.internalIifnames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "en*"
        "wg0"
      ];
      description = ''
        Motifs `iifname` (nftables) des interfaces par lesquelles un service
        interne accepte d'être joint. Consommé par `myLib.mkInternalPorts`, que
        les modules emploient à la place de
        `networking.firewall.allowedTCPPorts`.

        Alimenté par PLUSIEURS modules — le motif du LAN vient d'ici, `wg0`
        vient du serveur WireGuard — et les définitions se concatènent, la
        liste étant de type `listOf`.

        Vide (défaut) : les ports s'ouvrent globalement, ce qui reste correct
        sur un poste dont les interfaces vont et viennent. Non vide : le
        pare-feu doit être en nftables, sinon `extraInputRules` est ignoré en
        silence et les ports restent FERMÉS. L'assertion plus bas garde ce cas.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Hostname = "<profil>-<host>" (aligné sur le nom de la cible du flake, ce qui
      # permet à `nixos-rebuild --flake .#$(hostname)` de tomber juste).
      networking.hostName = hostName;

      assertions = [
        {
          # RFC 1123 : lettres minuscules, chiffres, tirets (pas en 1er/dernier).
          # Sans ça, un futur profil/host mal nommé échouerait tard, au rebuild,
          # avec un message systemd peu clair.
          assertion = builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" hostName != null;
          message = "networking.hostName \"${hostName}\" invalide (profil/host doivent être en minuscules alphanumériques + tirets, cf. RFC 1123).";
        }
        {
          # Le backend iptables ignore `extraInputRules` SANS RIEN DIRE : les
          # ports que mkInternalPorts croit ouvrir resteraient fermés, et sur
          # une machine administrée à distance ça se découvre en perdant SSH.
          assertion = cfg.internalIifnames == [ ] || config.networking.nftables.enable;
          message = "systemSettings.network.internalIifnames est renseigné mais le pare-feu est en iptables : les règles par interface seraient ignorées en silence. Active networking.nftables.enable.";
        }
      ];

      # Le DHCP global est coupé dans les deux cas : l'adressage vient soit de
      # NetworkManager, soit de systemd-networkd ci-dessous.
      networking.useDHCP = false;

      # LLMNR et mDNS coupés : resolved écoute sinon sur 5355 et 5353 sans
      # qu'on s'en serve, les noms de la maison venant du DNS, et LLMNR se
      # prête à l'empoisonnement de résolution sur un réseau partagé. Le
      # pare-feu les bloquait déjà, autant ne pas écouter du tout.
      services.resolved.settings.Resolve = {
        LLMNR = "no";
        MulticastDNS = "no";
      };
    }

    # NetworkManager gère les interfaces (DHCP inclus).
    (lib.mkIf (static == null) {
      networking.networkmanager.enable = true;
      # Activé d'office avec NetworkManager, mais aucune machine n'a de modem
      # 4G/5G : un démon de plus qui tournait à vide.
      networking.modemmanager.enable = false;
    })

    (lib.mkIf (static != null) {
      networking.networkmanager.enable = false;
      networking.useNetworkd = true;

      # Le LAN est la première interface interne ; le serveur WireGuard ajoute
      # `wg0` de son côté.
      systemSettings.network.internalIifnames = [ static.interface ];

      # nftables plutôt qu'iptables, et c'est ce qui débloque les deux verrous
      # qui manquaient au montage.
      #
      # `filterForward` d'abord : avec iptables, la chaîne FORWARD n'est filtrée
      # par RIEN. Le pare-feu NixOS ne touche que INPUT, et la chaîne que pose
      # `networking.nat` ne contient que des ACCEPT. Un client VPN avait donc un
      # accès IP complet à tout le LAN — box, imprimante, objets connectés — là
      # où l'intention était qu'il n'atteigne que les services de ce host.
      # `filterForward` n'existe QUE pour nftables, le module amont l'assert.
      # Les flux voulus sont réouverts par le module WireGuard, dans
      # `extraForwardRules`.
      #
      # Ensuite `extraInputRules`, qui permet d'ouvrir un port sur une interface
      # désignée par un MOTIF. Le module `networking.firewall.interfaces` ne sait
      # pas faire : il rend `iifname en*` sans guillemets, ce que nft refuse.
      #
      # Réserve à connaître : docker et libvirt posent leurs règles en iptables.
      # Les deux backends coexistent sans erreur mais s'évaluent dans un ordre
      # qui n'est pas garanti, et un conteneur peut alors être joignable en
      # contournant ces règles-ci. D'où l'avertissement plus bas.
      #
      # `systemSettings.apps` n'est PAS concerné : il fait tourner ses conteneurs
      # sous podman, qui n'écrit pas en iptables, et ne publie que le point
      # d'entrée sur la boucle locale. Le cas visé reste docker, qu'un profil
      # peut activer pour autre chose.
      networking.nftables.enable = true;
      networking.firewall.filterForward = true;

      # FILTRAGE DU CHEMIN INVERSE, en strict et POSÉ EXPLICITEMENT alors que
      # c'est déjà le défaut NixOS. Écrit ici parce qu'une décision d'accès en
      # dépend, et qu'une dépendance non écrite se perd.
      #
      # Ce que ça tient : les règles `networks:` d'Authelia contournent le
      # portail pour `10.8.0.0/24` (cf. profiles/server), et cette confiance
      # repose entièrement sur l'adresse SOURCE des paquets. En strict, nftables
      # rend `fib saddr . mark . iif oif exists` — il vérifie que la source
      # serait joignable PAR L'INTERFACE D'ARRIVÉE. Un appareil du LAN qui
      # émettrait sous une adresse du tunnel est donc jeté avant d'atteindre
      # nginx, la route vers `10.8.0.0/24` passant par wg0 et pas par le LAN.
      #
      # `"loose"` ne vérifierait que la routabilité, quelle que soit
      # l'interface, et rouvrirait ce chemin-là. Ne pas y toucher sans retirer
      # d'abord les `networks` d'Authelia.
      networking.firewall.checkReversePath = true;

      warnings = lib.optional config.virtualisation.docker.enable ''
        Ce host combine le pare-feu nftables (posé par systemSettings.network.staticIPv4)
        et docker, qui écrit ses propres règles en iptables. Les conteneurs peuvent
        devenir joignables en contournant networking.firewall — vérifie l'exposition
        réelle de chaque conteneur, ou repasse ce host en iptables.
      '';

      systemd.network.networks."10-lan" = {
        matchConfig.Name = static.interface;
        address = [ "${static.address}/${toString static.prefixLength}" ];
        routes = [ { Gateway = static.gateway; } ];
        dns = if static.nameservers == [ ] then [ static.gateway ] else static.nameservers;

        # Annonces de routeur IPv6 REFUSÉES en bloc, et c'est une décision de
        # sécurité, pas de propreté.
        #
        # Sans ça, la box attribue au host une adresse IPv6 GLOBALE par SLAAC.
        # Or IPv6 ne fait pas de NAT : tout port ouvert dans
        # `networking.firewall` devient alors joignable depuis internet, quoi
        # que la box redirige ou non. Constaté sur ce host — SSH et nginx
        # écoutaient sur `[::]` avec une adresse `2a01:…` publique, ce qui
        # exposait le port SSH et permettait de joindre nginx en contournant
        # entièrement Cloudflare. Le raisonnement « aucun port redirigé, donc
        # rien n'est joignable » ne vaut que pour IPv4.
        #
        # Refuser les RA supprime la classe entière plutôt que de la rattraper
        # port par port. Ça reste cohérent avec l'intention de ce bloc : si l'on
        # déclare une adresse statique, c'est pour que l'adressage ne dépende ni
        # d'un bail ni d'une annonce — une adresse SLAAC bouge avec le préfixe de
        # l'opérateur.
        #
        # L'IPv6 de lien local (fe80::) subsiste, joignable seulement depuis le
        # même segment, donc au même niveau de confiance que le LAN en IPv4. Et
        # le DNS annoncé par la box disparaît du même coup, lui qui doublait le
        # résolveur choisi ci-dessus et faisait perdre les réécritures locales
        # au premier hoquet de dnsmasq.
        #
        # Si un jour l'IPv6 sortante devient nécessaire, la voie est de rouvrir
        # les RA et de déplacer 443, 53 et le port SSH vers
        # `networking.firewall.interfaces`, en ne laissant global que le port
        # UDP de WireGuard.
        networkConfig.IPv6AcceptRA = false;

        # Sans ça, systemd-networkd-wait-online se contente de n'importe quelle
        # interface configurée (docker0 suffit) et network-online.target est
        # atteinte avant que le LAN soit joignable.
        linkConfig.RequiredForOnline = "routable";
      };
    })
  ];
}
