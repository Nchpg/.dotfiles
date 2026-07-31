{
  config,
  lib,
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

  # Destinations que le tunnel ne relaie JAMAIS, quelle que soit l'option : tout
  # ce qui n'est pas de l'internet public. Sans cette liste, « sortie internet »
  # voudrait dire « accès au LAN » dès que la destination est privée, et le
  # filtrage ne servirait à rien. Les adresses de ce host restent joignables :
  # elles sont délivrées localement et ne traversent pas la chaîne de forward.
  nonRoutable = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "127.0.0.0/8"
    "100.64.0.0/10"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];

  # Fabrique une configuration cliente complète, QR compris, sans jamais écrire
  # la clé privée où que ce soit : elle ne traverse que la sortie du terminal.
  # C'est le remplaçant direct de l'interface d'appairage.
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
      if [ $# -lt 2 ]; then
        cat >&2 <<'USAGE'
      usage: wg-new-peer <nom> <adresse-dans-le-tunnel>

        wg-new-peer telephone-nathan 10.8.0.2

      Affiche la configuration cliente et son QR code, puis l'extrait Nix à
      coller dans le profil. La clé privée n'est écrite nulle part : copie-la
      depuis ce terminal, ou scanne le QR, et referme.

      À lancer en root : la clé publique du serveur est dérivée de sa clé privée.
      USAGE
        exit 2
      fi

      name=$1
      address=$2

      if [ ! -r ${privateKeyPath} ]; then
        echo "impossible de lire ${privateKeyPath} — relance en root" >&2
        exit 1
      fi

      server_public=$(wg pubkey < ${privateKeyPath})
      private=$(wg genkey)
      public=$(printf '%s' "$private" | wg pubkey)
      psk=$(wg genpsk)

      conf=$(cat <<EOF
      [Interface]
      PrivateKey = $private
      Address = $address/32
      ${lib.optionalString (cfg.dns != [ ]) "DNS = ${lib.concatStringsSep ", " cfg.dns}"}

      [Peer]
      PublicKey = $server_public
      PresharedKey = $psk
      Endpoint = ${toString cfg.host}:${toString cfg.port}
      AllowedIPs = ${lib.concatStringsSep ", " cfg.allowedIPs}
      # Les clients mobiles passent derrière un NAT opérateur qui ferme les
      # associations UDP inactives en ~30 s : sans keepalive, le tunnel semble
      # « mort » jusqu'à ce que le téléphone émette de lui-même.
      PersistentKeepalive = 25
      EOF
      )

      printf '%s\n' "$conf"
      echo
      echo "── QR (à scanner depuis l'application WireGuard) ──"
      printf '%s' "$conf" | qrencode -t ansiutf8
      echo
      echo "── 1. à ranger dans les secrets SYSTÈME ──"
      echo "     secrets edit wireguard/''${name}_preshared_key"
      cat <<EOF
      wireguard:
        ''${name}_preshared_key: $psk
      EOF
      echo
      echo "── 2. à ajouter dans profiles/server, puis nixos-rebuild switch ──"
      cat <<EOF
      {
        name = "$name";
        publicKey = "$public";
        address = "$address";
        presharedKeyKey = "wireguard/''${name}_preshared_key";
      }
      EOF
      echo
      echo "L'ORDRE COMPTE : le secret sops doit exister AVANT le rebuild, sinon"
      echo "l'activation échoue faute de pouvoir déchiffrer la clé pré-partagée."
      echo "Tant que le rebuild n'est pas fait, ce peer n'est pas autorisé."
    '';
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
        « vient du VPN » — cf. les règles d'Authelia dans profiles/server.
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
    ];

    warnings = lib.optional (peersWithoutPsk != [ ]) ''
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
    # 53, SSH) acceptent d'être joints depuis le tunnel, cf. myLib.mkInternalPorts.
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
    # `mkForce` et pas une définition qui s'ajoute, et c'est le point à ne pas
    # rater : dès que `filterForward` est vrai, `networking.nat` écrit lui-même
    # dans cette option un `ip saddr { <internalIPs> } accept` sans aucune
    # restriction de destination. Il rouvre donc EXACTEMENT ce qu'on ferme ici,
    # et comme l'ordre des définitions d'une option `lines` n'est pas garanti,
    # on ne peut pas se contenter de mettre une règle plus stricte avant. Vérifié
    # sur le ruleset produit : sans ce mkForce, la règle du module amont est bien
    # là et les peers atteignent tout le LAN.
    #
    # Conséquence à connaître : si un autre module vient un jour poser ses
    # propres règles de traversée, elles seront écrasées sans bruit.
    networking.firewall.extraForwardRules = lib.mkForce (
      lib.optionalString cfg.peerInternetAccess ''
        iifname "wg0" oifname != "wg0" ip daddr != { ${lib.concatStringsSep ", " nonRoutable} } accept comment "peers vers internet"
      ''
      + lib.optionalString (cfg.peerLanAccess != [ ]) ''
        iifname "wg0" ip daddr { ${lib.concatStringsSep ", " cfg.peerLanAccess} } accept comment "peers vers le LAN, liste explicite"
      ''
    );

    # Masquerade vers l'extérieur, pour que le tunnel complet sorte par la maison
    # et que les autres appareils du LAN n'aient pas besoin d'une route de retour
    # vers le tunnel.
    #
    # Le trafic destiné à CE host n'est pas concerné : il est délivré localement,
    # sans passer par POSTROUTING. nginx voit donc la vraie adresse `10.8.0.x`,
    # ce qui est tout l'intérêt de l'opération.
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
    # `myLib.mkInternalPorts` comme le reste : c'est le seul du parc qui doit
    # répondre à un paquet venu d'internet. Il ne trahit rien pour autant,
    # WireGuard ne répondant RIEN à un paquet non authentifié.
    networking.firewall.allowedUDPPorts = [ cfg.port ];

    environment.systemPackages = [
      pkgs-stable.wireguard-tools
      newPeer
    ];
  };
}
