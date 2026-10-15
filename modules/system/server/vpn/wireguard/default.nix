{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# WireGuard servi par systemd-networkd, sans conteneur ni interface web.
#
# Remplace wg-easy, et le remplacement vaut mieux que ce qu'il coûte :
#
#   - Les clés privées des clients n'existent JAMAIS sur ce host. wg-easy les
#     gardait pour pouvoir réafficher un QR code plus tard, si bien qu'un volume
#     compromis livrait l'accès VPN de toute la famille. Ici le dépôt ne contient
#     que des clés publiques, et les clés pré-partagées vivent dans sops : elles
#     ne donnent l'accès à personne toutes seules, faute de la clé privée que
#     l'appareil est le seul à détenir.
#   - Les peers gardent leur vraie adresse `10.8.0.x`. wg-easy les masquait tous
#     derrière son conteneur, rendant les appareils indiscernables ; les règles
#     d'Authelia peuvent désormais distinguer QUI appelle.
#   - Le trafic des peers passe par `networking.firewall` comme n'importe quel
#     client du LAN. Docker insérait ses règles en amont et court-circuitait ce
#     pare-feu.
#   - Plus de digest à suivre, d'image à migrer, ni de démon docker sur le host.
#
# Ce qu'on perd : l'appairage au clic. Le script `wg-new-peer` le remplace — il
# fabrique la paire de clés, affiche la configuration cliente et son QR code,
# puis oublie la clé privée. Cf. son aide et le commentaire plus bas.
let
  cfg = config.systemSettings.vpn.wireguard;
  static = config.systemSettings.network.staticIPv4;

  privateKeyPath = config.sops.secrets.${cfg.privateKeyKey}.path;

  peerAddresses = map (p: p.address) cfg.peers;

  presharedKeyKeys = lib.unique (
    map (p: p.presharedKeyKey) (lib.filter (p: p.presharedKeyKey != null) cfg.peers)
  );

  peersWithoutPsk = map (p: p.name) (lib.filter (p: p.presharedKeyKey == null) cfg.peers);

  forNetworkd = {
    owner = "systemd-network";
    mode = "0400";
    restartUnits = [ "systemd-networkd.service" ];
  };

  # Fabrique une configuration cliente complète, QR compris, sans jamais écrire
  # la clé privée où que ce soit (cf. wg-new-peer.sh, à côté).
  #
  # La clé publique du serveur est DÉRIVÉE de sa clé privée à l'exécution plutôt
  # que déclarée en double dans le dépôt : une copie finirait par diverger, et
  # une configuration cliente avec la mauvaise clé serveur échoue sans message
  # explicite. D'où le besoin de root pour lire /run/secrets.
  newPeer = pkgs-stable.writeShellApplication {
    name = "wg-new-peer";
    runtimeInputs = [
      pkgs-stable.wireguard-tools
      pkgs-stable.qrencode
    ];
    text = ''
      private_key_path=${lib.escapeShellArg privateKeyPath}
      dns_line=${
        lib.escapeShellArg (
          lib.optionalString (cfg.dns != [ ]) "DNS = ${lib.concatStringsSep ", " cfg.dns}"
        )
      }
      endpoint=${lib.escapeShellArg "${toString cfg.host}:${toString cfg.port}"}
      allowed_ips=${lib.escapeShellArg (lib.concatStringsSep ", " cfg.allowedIPs)}
    ''
    + builtins.readFile ./wg-new-peer.sh;
  };
in
{
  options.systemSettings.vpn.wireguard = {
    enable = lib.mkEnableOption "serveur WireGuard (systemd-networkd)";

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "vpn.exemple.fr";
      description = ''
        Nom public (ou IP publique) inscrit comme `Endpoint` dans les
        configurations clientes.

        C'est la seule valeur que les clients ne peuvent pas deviner, et une
        erreur ici ne se voit PAS depuis le LAN : les profils fonctionnent à la
        maison et échouent dehors.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = ''
        Port UDP de WireGuard, à rediriger sur la box. Le seul port de ce module
        volontairement joignable depuis internet : WireGuard ne répond RIEN à un
        paquet non authentifié, un scan ne le distingue pas d'un port fermé.
      '';
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "10.8.0.0/24";
      description = ''
        Plage d'adresses du tunnel, en notation CIDR. Doit rester disjointe du
        LAN, sinon les clients ne savent plus quelle route emprunter pour joindre
        la maison.

        C'est cette plage que les autres modules autorisent pour reconnaître
        « vient du VPN » — cf. les règles d'Authelia de modules/system/server/nextcloud.
      '';
    };

    serverAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.8.0.1";
      description = "Adresse du serveur dans le tunnel, à prendre dans `subnet`.";
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional (static != null) static.address;
      defaultText = lib.literalExpression "[ systemSettings.network.staticIPv4.address ]";
      description = ''
        Résolveurs inscrits dans les configurations clientes, dans l'ORDRE
        d'interrogation.

        En mettre PLUSIEURS n'est pas décoratif quand le premier est un résolveur
        local qui réécrit des noms : s'il s'arrête, les clients basculent sur le
        suivant, perdent la réécriture — donc repassent par le chemin public et
        son portail — mais continuent de résoudre le reste.

        Attention : ces valeurs ne sont lues qu'à la fabrication d'une
        configuration cliente. Les modifier ici ne change RIEN aux appareils déjà
        appairés, il faut leur regénérer un profil.
      '';
    };

    allowedIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "0.0.0.0/0"
        "::/0"
      ];
      description = ''
        Routes poussées aux clients. Le défaut est un tunnel COMPLET : tout sort
        par la maison, ce qui protège aussi sur un WiFi public et évite la classe
        de pannes « je joins Nextcloud mais pas le NAS » propre aux tunnels
        partiels.

        `::/0` est là pour COLMATER UNE FUITE, pas pour transporter de l'IPv6. Le
        tunnel est en IPv4 seulement ; sans cette route, un client sur un réseau
        double pile envoie tout son trafic IPv6 par sa connexion locale, hors du
        tunnel — « tout sort par la maison » devenait faux sans que rien ne le
        signale. En la poussant, le client route son IPv6 dans le tunnel, où elle
        n'aboutit pas : les destinations IPv6-seules deviennent injoignables
        pendant la connexion, ce qui est le comportement voulu.

        Si un client refuse de monter à cause de `::/0` — l'interface du tunnel
        n'ayant pas d'adresse IPv6 — retire-la pour celui-là.

        Comme `dns`, ne concerne que les profils fabriqués ensuite : les appareils
        déjà appairés gardent les routes de leur profil.
      '';
    };

    privateKeyKey = lib.mkOption {
      type = lib.types.str;
      default = "wireguard/server_private_key";
      description = ''
        Clé sops de la clé privée du serveur, générée par `wg genkey`. Contenu
        brut, sans nom de variable ni saut de ligne superflu.

        Nommée par RÔLE et non par machine : il n'y a qu'un serveur, et ce
        module vit dans un profil qui peut s'appliquer à plusieurs hosts — un
        nom de machine y serait faux dès le second. Les CLIENTS, eux, se
        nomment par machine, cf. modules/system/vpn/client.
      '';
    };

    peers = lib.mkOption {
      default = [ ];
      description = ''
        Appareils autorisés. Seule la clé PUBLIQUE figure ici — les clés privées
        restent sur les appareils, cf. `wg-new-peer`.
      '';
      example = lib.literalExpression ''
        [
          {
            name = "telephone";
            publicKey = "abc…=";
            address = "10.8.0.2";
          }
        ]
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Nom de l'appareil. Purement documentaire, mais c'est lui qu'on lit à la révocation.";
            };

            publicKey = lib.mkOption {
              type = lib.types.str;
              description = "Clé publique de l'appareil, telle que produite par `wg-new-peer`.";
            };

            address = lib.mkOption {
              type = lib.types.str;
              example = "10.8.0.2";
              description = ''
                Adresse de l'appareil dans le tunnel. Unique, et c'est elle que
                les autres services verront comme adresse source — ce qui permet
                une règle par appareil, impossible du temps où wg-easy les
                masquait tous derrière une seule adresse.
              '';
            };

            presharedKeyKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "wireguard/gram_preshared_key";
              description = ''
                Clé sops de la clé PRÉ-PARTAGÉE de cet appareil, produite par
                `wg genpsk` (c'est ce que fait `wg-new-peer`).

                Ce qu'elle apporte, et rien d'autre : elle est mélangée au
                handshake, donc du trafic enregistré aujourd'hui reste
                indéchiffrable le jour où X25519 tombe. Ce n'est PAS un second
                facteur — c'est un secret statique, rangé dans le même fichier
                que la clé privée sur l'appareil, donc qui vole l'un vole
                l'autre.

                Un secret PAR APPAREIL : une clé commune se révoquerait pour
                tout le monde à la fois, et le peer révoqué la connaîtrait
                encore.

                `null` désactive. La valeur doit être IDENTIQUE des deux côtés :
                un décalage donne une poignée de main qui échoue en boucle, sans
                message plus précis que « handshake did not complete ».
              '';
            };

            trusted = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Appareil de CONFIANCE : il figure dans `trustedSources`, la liste
                des sources admises sur les services réservés à l'administrateur
                (le coffre, par exemple), et pas seulement dans le tunnel.

                Faux par défaut : un téléphone de la famille entre dans le tunnel
                sans entrer partout. Porté par le peer lui-même plutôt que par une
                liste de noms ailleurs, pour qu'un peer renommé ne perde pas son
                accès en silence.
              '';
            };
          };
        }
      );
    };

    peerInternetAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Laisse les peers ressortir vers internet par cette maison, ce qui est le
        sens même d'un tunnel complet : sur un WiFi public, le trafic est
        chiffré jusqu'ici.

        Ne concerne QUE le trafic qui traverse ce host. Les services du host
        lui-même (nginx, dnsmasq) sont joints en local et ne passent pas par le
        filtrage de forward, donc les couper ici ne les rend pas injoignables.

        Les destinations privées restent exclues quoi qu'il arrive, cf.
        `peerLanAccess`.
      '';
    };

    trustedSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = map (p: "${p.address}/32") (lib.filter (p: p.trusted) cfg.peers);
      defaultText = lib.literalExpression "les adresses en /32 des peers `trusted`";
      description = ''
        Adresses des appareils de confiance (`peers.*.trusted`), en notation
        CIDR, à reprendre dans un `allowedNetworks`. Dérivé : l'autorisation
        suit l'adresse le jour où elle change.
      '';
    };

    selfSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if static != null then "${static.address}/32" else null;
      defaultText = lib.literalExpression "l'adresse du LAN de ce host, en /32";
      description = ''
        Source sous laquelle ce host SE VOIT lui-même quand il vise sa propre
        adresse de tunnel, à admettre là où une sonde locale doit passer.

        Ce n'est PAS `serverAddress` : le masquerade posé par `networking.nat`
        (cf. plus bas) réécrit la source de tout paquet émis depuis la plage du
        tunnel, y compris ceux que ce host s'envoie à lui-même. nginx et
        Authelia voient donc l'adresse du LAN. Admettre cette source est sans
        danger : pour se présenter sous elle, il faut la détenir — une source
        falsifiée n'établit pas de poignée de main TCP.
      '';
    };

    peerLanAccess = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.1.20" ];
      description = ''
        Adresses ou préfixes du LAN qu'un peer a le droit de joindre À TRAVERS
        ce host, en plus de ce host lui-même.

        VIDE par défaut, et c'est le point qui change tout : sans filtrage du
        forward, un appareil appairé avait un accès IP complet au LAN entier,
        box et objets connectés compris. Un téléphone familial compromis
        devenait un pied dans la maison, pas un accès à Nextcloud.

        Les peers ne se joignent pas non plus ENTRE EUX : rien ne ressort de
        `wg0` par `wg0`. Un appareil compromis ne peut donc pas scanner les
        autres.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.host != null;
        message = "systemSettings.vpn.wireguard.host n'est pas renseigné — les configurations clientes pointeraient dans le vide. Mets-y le nom public (ou l'IP publique) de ta connexion.";
      }
      {
        # Le port UDP doit être redirigé sur la box vers une adresse qui ne bouge
        # pas, et le NAT a besoin de connaître l'interface externe.
        assertion = static != null;
        message = "systemSettings.vpn.wireguard exige un adressage statique (systemSettings.network.staticIPv4) : le port UDP doit être redirigé vers une adresse qui ne bouge pas.";
      }
      {
        # Deux peers sur la même adresse : WireGuard route vers le dernier
        # déclaré, et l'autre appareil cesse de fonctionner sans message.
        assertion = lib.length (lib.unique peerAddresses) == lib.length peerAddresses;
        message = "systemSettings.vpn.wireguard.peers : deux appareils partagent la même adresse. Chacune doit être unique dans le tunnel.";
      }
      {
        assertion = !lib.elem cfg.serverAddress peerAddresses;
        message = "systemSettings.vpn.wireguard.peers : un appareil utilise ${cfg.serverAddress}, qui est l'adresse du serveur (serverAddress).";
      }
      {
        # RÉSOLVEUR POUSSÉ QUI N'ÉCOUTE PAS, la panne la plus silencieuse que
        # ce module puisse produire.
        #
        # Le pare-feu ouvre le port 53 sur `wg0` — `mkInternalPorts` y met le
        # tunnel comme le LAN — donc rien, côté filtrage, ne signale le
        # problème. Mais dnsmasq n'écoute QUE sur la boucle locale et sur
        # l'adresse du LAN (cf. `listen-address` dans modules/system/server/dns),
        # jamais sur l'adresse du tunnel. Un peer à qui l'on pousserait
        # `serverAddress` comme résolveur recevrait donc un refus de connexion
        # sur chaque requête, et perdrait TOUTE résolution tant que le tunnel
        # est monté — y compris pour les noms publics.
        #
        # Vérifié le 15 août 2026 : `ss -tuln` sur think ne montre le port 53
        # que sur 127.0.0.1 et 192.168.1.32 (les écoutes sur 10.89.x sont
        # aardvark-dns, pour les conteneurs).
        #
        # Deux façons de satisfaire cette assertion : ne pas pousser cette
        # adresse, ou ajouter l'adresse du tunnel au `listen-address` du module
        # DNS — ce dernier suppose aussi d'ordonner dnsmasq après wg0, son
        # `bind-interfaces` exigeant que l'adresse existe au démarrage.
        assertion =
          !(lib.elem cfg.serverAddress cfg.dns)
          || lib.elem cfg.serverAddress (config.services.dnsmasq.settings.listen-address or [ ]);
        message = "systemSettings.vpn.wireguard.dns pousse ${cfg.serverAddress} aux peers, mais aucun résolveur n'écoute sur cette adresse : ils perdraient toute résolution dans le tunnel. Ajoute-la au listen-address de dnsmasq, ou retire-la de `dns`.";
      }
    ];

    warnings =
      lib.optional
        (static != null && lib.elem static.address cfg.dns && !lib.elem "0.0.0.0/0" cfg.allowedIPs)
        ''
          systemSettings.vpn.wireguard : le résolveur poussé aux peers est ${static.address}, une adresse du LAN,
          alors que `allowedIPs` ne route que ${lib.concatStringsSep ", " cfg.allowedIPs} dans le tunnel.
          Un peer la joindra donc par le réseau où il se trouve : ça marche à la maison, et nulle part ailleurs.
          C'est le DÉFAUT de l'option `dns`, hérité du temps où le tunnel était complet — le laisser en place
          sur un tunnel restreint casse la résolution des appareils dès qu'ils sortent.
        ''
      ++ lib.optional (peersWithoutPsk != [ ]) ''
        systemSettings.vpn.wireguard : ${lib.concatStringsSep ", " peersWithoutPsk} n'ont pas de clé pré-partagée (presharedKeyKey).
        Leur trafic, s'il est enregistré aujourd'hui, sera déchiffrable le jour où X25519 tombe.
        `sudo wg-new-peer <nom> <adresse>` en génère une ; la remplacer sur un peer existant demande
        de regénérer aussi son profil client.
      '';

    # Lues par systemd-networkd, qui tourne sous son propre utilisateur.
    #
    # networkd lit ces fichiers au montage de l'interface et ne les surveille
    # pas : sans `restartUnits`, une rotation régénérerait le fichier sans que
    # wg0 la reprenne.
    sops.secrets = {
      ${cfg.privateKeyKey} = forNetworkd;
    }
    // lib.listToAttrs (map (key: lib.nameValuePair key forNetworkd) presharedKeyKeys);

    systemd.network = {
      netdevs."50-wg0" = {
        netdevConfig = {
          Kind = "wireguard";
          Name = "wg0";
        };

        wireguardConfig = {
          PrivateKeyFile = privateKeyPath;
          ListenPort = cfg.port;
        };

        # Un /32 par appareil, et pas la plage entière : `AllowedIPs` sert AUSSI
        # de filtre en entrée côté serveur, un peer ne peut donc pas émettre sous
        # l'adresse d'un autre. C'est ce qui rend fiables les règles par appareil.
        #
        # Pas de PersistentKeepalive ici : c'est au client de maintenir
        # l'association à travers son NAT, le serveur ne connaît pas son endpoint
        # avant qu'il se présente.
        wireguardPeers = map (
          peer:
          {
            PublicKey = peer.publicKey;
            AllowedIPs = [ "${peer.address}/32" ];
          }
          // lib.optionalAttrs (peer.presharedKeyKey != null) {
            PresharedKeyFile = config.sops.secrets.${peer.presharedKeyKey}.path;
          }
        ) cfg.peers;
      };

      networks."50-wg0" = {
        matchConfig.Name = "wg0";
        address = [ "${cfg.serverAddress}/${lib.last (lib.splitString "/" cfg.subnet)}" ];

        # Même décision que sur le LAN (cf. modules/system/network), par
        # symétrie et par avance. Sans effet aujourd'hui : les `AllowedIPs` en
        # /32 IPv4 jettent tout paquet IPv6 venu d'un peer, annonce de routeur
        # comprise. Ça cesse d'être vrai le jour où un peer reçoit `::/0`, et
        # cette ligne-là ne bougera pas.
        networkConfig.IPv6AcceptRA = false;
      };
    };

    # `wg0` compte parmi les interfaces internes : les services du host (443,
    # 53, SSH) acceptent d'être joints depuis le tunnel, cf. myLib.server.mkInternalPorts.
    systemSettings.network.internalIifnames = [ "wg0" ];

    # Ce que les peers ont le droit de TRAVERSER, la chaîne de forward étant en
    # refus par défaut (cf. filterForward dans modules/system/network).
    #
    # Sans ces règles le tunnel complet ne sort plus ; avec elles, il sort sans
    # donner accès au LAN. Le trafic de RETOUR est déjà accepté en amont par
    # l'état de connexion, il n'y a donc rien à écrire pour lui.
    #
    # `oifname != "wg0"` isole aussi les peers ENTRE EUX : un appareil compromis
    # ne voit pas les autres.
    #
    # Par `forwardRules` et non `networking.firewall.extraForwardRules` : la
    # règle sans restriction de destination que `networking.nat` écrit dans
    # cette dernière rouvrirait EXACTEMENT ce qu'on ferme ici. Le module réseau
    # l'écarte en rendant `forwardRules` par un `mkForce` unique — cf. la
    # description de l'option.
    systemSettings.network.forwardRules =
      lib.optionalString cfg.peerInternetAccess ''
        iifname "wg0" oifname != "wg0" ip daddr != { ${lib.concatStringsSep ", " myLib.server.nonRoutableIPv4} } accept comment "peers vers internet"
      ''
      + lib.optionalString (cfg.peerLanAccess != [ ]) ''
        iifname "wg0" ip daddr { ${lib.concatStringsSep ", " cfg.peerLanAccess} } accept comment "peers vers le LAN, liste explicite"
      '';

    # Masquerade vers l'extérieur, pour que le tunnel complet sorte par la maison
    # et que les autres appareils du LAN n'aient pas besoin d'une route de retour
    # vers le tunnel.
    #
    # Le trafic D'UN PEER VERS CE HOST n'est pas concerné : il arrive par INPUT,
    # est délivré localement, et ne traverse jamais POSTROUTING. nginx voit donc
    # la vraie adresse `10.8.0.x`, ce qui est tout l'intérêt de l'opération —
    # c'est ce qui fait fonctionner les règles `networks` d'Authelia.
    #
    # CE QUI EST BIEN CONCERNÉ, en revanche, et qui coûte une demi-journée à
    # comprendre : le trafic que CE HOST ÉMET vers sa propre adresse de tunnel.
    # Un paquet localement engendré traverse OUTPUT puis POSTROUTING, la règle
    # `ip saddr 10.8.0.0/24 masquerade` correspond — elle n'exclut aucune
    # interface, pas même `lo` — et la source est réécrite en 192.168.1.32.
    # La socket, elle, continue d'annoncer `10.8.0.1`, donc `curl --write-out
    # %{local_ip}` et `ip route get` disent tous les deux le contraire de ce qui
    # arrive vraiment à nginx.
    #
    # CONSÉQUENCE PRATIQUE : depuis think, une requête vers `cloud.vpn.…` est vue
    # par Authelia comme venant du LAN, donc aucune règle `bypass` de la plage du
    # tunnel ne s'y applique et elle tombe sur `default_policy = deny`. Le chemin
    # du VPN n'est PAS empruntable depuis la machine qui le sert. Constaté en
    # voulant y placer une sonde de surveillance.
    #
    # `internalIPs` et non `internalInterfaces` avec un `externalInterface` : le
    # module réseau identifie la carte par un MOTIF (`en*` par défaut), que
    # networkd accepte mais dont les règles de NAT ne peuvent rien faire — un
    # `-o en*` ne correspond à aucune interface. Le masquerade par sous-réseau
    # source s'en affranchit, et cible plus juste : seul le trafic du tunnel est
    # réécrit, quelle que soit l'interface par laquelle il sort.
    #
    # `externalInterface` reste nul, ce que le module amont n'exige que pour
    # `dmzHost` et `forwardPorts`, dont on ne se sert pas.
    networking.nat = {
      enable = true;
      internalIPs = [ cfg.subnet ];
    };

    # wg0 n'est PAS dans `trustedInterfaces` : un peer traverse le pare-feu comme
    # un appareil du LAN, et n'atteint donc que les ports ouverts (443, 53, SSH).
    #
    # Le port du tunnel, lui, s'ouvre GLOBALEMENT et pas par
    # `myLib.server.mkInternalPorts` comme le reste : c'est le seul du parc qui doit
    # répondre à un paquet venu d'internet. Il ne trahit rien pour autant,
    # WireGuard ne répondant RIEN à un paquet non authentifié.
    networking.firewall.allowedUDPPorts = [ cfg.port ];

    environment.systemPackages = [
      pkgs-stable.wireguard-tools
      newPeer
    ];
  };
}
