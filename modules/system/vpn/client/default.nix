{
  config,
  lib,
  ...
}:

# Côté CLIENT d'un tunnel WireGuard, pour joindre les services de la maison
# depuis l'extérieur. Le côté serveur vit dans modules/system/server/vpn.
#
# Par `wg-quick` et non par le module natif `networking.wireguard` : wg-quick
# sait poser le routage par politique qu'exige un tunnel COMPLET, et gère le
# résolveur — il remplace celui du système pendant que le tunnel est monté, puis
# le rétablit. C'est ce qui permet aux réécritures de dnsmasq de s'appliquer à
# distance, donc à `cloud.` de répondre l'adresse du LAN et de contourner le
# portail comme à la maison.
#
# Rien n'est démarré automatiquement, cf. `autostart`.
let
  cfg = config.systemSettings.vpn.client;
in
{
  options.systemSettings.vpn.client = {
    enable = lib.mkEnableOption "client WireGuard (tunnel vers la maison)";

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.8.0.3/32";
      description = ''
        Adresse de CET appareil dans le tunnel, avec son préfixe.

        Doit correspondre EXACTEMENT à ce que le serveur déclare pour ce peer :
        côté serveur, `AllowedIPs` sert aussi de filtre en entrée, donc un
        paquet émis sous une autre adresse est jeté. Symptôme d'un décalage :
        poignée de main réussie, et rien qui passe.

        Un `/32` et non le préfixe du réseau : sinon le client croirait joindre
        les autres peers en direct.
      '';
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "vpn.exemple.fr:51820";
      description = ''
        Point de terminaison public du serveur, hôte et port. Résolu par le
        résolveur du réseau où l'on se trouve, avant que le tunnel existe — donc
        indépendant de tout ce que la maison peut avoir de cassé.
      '';
    };

    serverPublicKey = lib.mkOption {
      type = lib.types.str;
      description = ''
        Clé PUBLIQUE du serveur. Publique, donc elle vit en clair dans le dépôt.

        À lire sur le serveur : `sudo wg show wg0 public-key`. Elle est dérivée
        de sa clé privée, donc la recopier ici crée une duplication qui peut
        diverger — une rotation de la clé serveur oblige à revenir ici.
      '';
    };

    privateKeyKey = lib.mkOption {
      type = lib.types.str;
      example = "wireguard/gram_private_key";
      description = ''
        Clé sops de la clé privée de CET appareil. Contenu brut, tel que produit
        par `wg genkey`.

        SANS défaut, à dessein : un client se nomme par MACHINE, et il peut y en
        avoir plusieurs. Un défaut comme `client_private_key` marcherait pour le
        premier puis mentirait pour tous les suivants, ce qui est le pire des
        deux mondes — nommer explicitement force à choisir, et la déclaration
        vit de toute façon dans le fichier de la machine.

        Pas non plus dérivée de `networking.hostName` : celui-ci porte le profil
        construit (`personal-gram`, `server-gram`), donc le nom changerait selon
        la cible et le secret deviendrait introuvable sous l'autre.

        À générer sur l'appareil lui-même : la clé privée d'un client n'a aucune
        raison de transiter par le serveur, contrairement à ce que faisait
        wg-easy, qui les conservait toutes.
      '';
    };

    presharedKeyKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wireguard/gram_preshared_key";
      description = ''
        Clé sops de la clé PRÉ-PARTAGÉE de cet appareil. Doit désigner le MÊME
        secret que le `presharedKeyKey` du peer correspondant côté serveur : les
        deux hosts déchiffrent le même fichier.

        Ce qu'elle apporte : mélangée au handshake, elle rend indéchiffrable du
        trafic enregistré aujourd'hui le jour où X25519 tombe. Ce n'est pas un
        second facteur, elle est rangée à côté de la clé privée.

        `null` désactive. Un décalage entre les deux côtés donne une poignée de
        main qui échoue en boucle, sans message plus précis que « handshake did
        not complete » — donc à changer des deux côtés en même temps.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "192.168.1.32"
        "192.168.1.254"
      ];
      description = ''
        Résolveurs employés PENDANT que le tunnel est monté, dans l'ordre
        d'interrogation. wg-quick remplace le résolveur du système et le
        rétablit à la fermeture.

        Y mettre le résolveur de la maison est ce qui fait que `cloud.` répond
        l'adresse du LAN à distance, donc que la synchro contourne le portail.
        En mettre un SECOND en repli évite de perdre toute résolution si le
        premier s'arrête.

        Liste vide : le résolveur du réseau visité est conservé, et les noms
        internes ne résolvent pas.
      '';
    };

    allowedIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.8.0.0/24" ];
      description = ''
        Destinations envoyées dans le tunnel, en notation CIDR. C'est une table
        de routage et rien d'autre : un paquet y entre si son adresse de
        DESTINATION tombe dedans, le nom visé n'entre pas en ligne de compte.

        SANS défaut utilisable, à dessein, et c'est l'option de ce module dont
        une valeur oubliée fait le plus de dégâts en silence. Le défaut d'usage
        est `0.0.0.0/0`, un tunnel COMPLET, qui détourne tout le trafic de la
        machine par la maison — donc bride le débit sur une connexion plus
        rapide, et surtout entre en conflit à la maison avec le préfixe déjà
        connecté sur le WiFi : wg-quick tente d'ajouter une route pour un réseau
        directement joignable, ce qui échoue, et le tunnel casse précisément là
        où on voulait qu'il tourne. L'assertion oblige donc à choisir.

        La valeur du parc est le seul sous-réseau du tunnel, `10.8.0.0/24` : les
        services de la maison se joignent par leur adresse DANS le tunnel (cf.
        `cloud.vpn.` et l'alias ssh `think`), le trafic ordinaire sort par le
        réseau où la machine se trouve, et le tunnel peut rester monté en
        permanence sans rien détourner.

        Ne pas y mettre `::/0` avec un tunnel restreint : cette route ne se
        justifiait que pour colmater la fuite IPv6 d'un tunnel complet, qui
        prétendait tout transporter. Sans cette prétention, il n'y a rien à
        colmater et elle ne ferait que rendre injoignables les destinations
        IPv6-seules.
      '';
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Monte le tunnel au démarrage.

        FAUX par défaut : c'est au host de choisir. Le tunnel ne transportant
        que le sous-réseau du VPN (pas un tunnel complet), le monter en
        permanence ne détourne pas le reste du trafic ; gram le fait.

        Bascule manuelle :
          sudo systemctl start wg-quick-wg0
          sudo systemctl stop  wg-quick-wg0
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # address, endpoint, serverPublicKey et privateKeyKey n'ont pas de
        # défaut : un oubli y est une erreur d'évaluation qui nomme l'option.
        # Une liste vide, elle, serait acceptée sans erreur et le tunnel ne
        # transporterait rien, ce qui se diagnostique mal — poignée de main
        # réussie, aucun paquet.
        assertion = cfg.allowedIPs != [ ];
        message = "systemSettings.vpn.client.allowedIPs est vide : le tunnel monterait sans router quoi que ce soit dedans. Mets-y le sous-réseau du tunnel (10.8.0.0/24), pas 0.0.0.0/0 — cf. la description de l'option.";
      }
    ];

    # Lues par wg-quick, qui tourne en root : pas de propriétaire à poser.
    #
    # `restartUnits` pour la même raison que côté serveur : wg-quick lit ces
    # fichiers au montage de l'interface et ne les surveille pas. Sans ça, une
    # rotation de clé régénère le fichier sans que le tunnel la reprenne, et le
    # symptôme est un tunnel qui marche jusqu'au prochain redémarrage.
    sops.secrets =
      let
        forTunnel = {
          restartUnits = [ "wg-quick-wg0.service" ];
        };
      in
      {
        ${cfg.privateKeyKey} = forTunnel;
      }
      // lib.optionalAttrs (cfg.presharedKeyKey != null) {
        ${cfg.presharedKeyKey} = forTunnel;
      };

    networking.wg-quick.interfaces.wg0 = {
      address = [ cfg.address ];
      privateKeyFile = config.sops.secrets.${cfg.privateKeyKey}.path;
      inherit (cfg) autostart dns;

      peers = [
        (
          {
            publicKey = cfg.serverPublicKey;
            inherit (cfg) allowedIPs endpoint;
            # Le client est derrière un NAT qui ferme les associations UDP
            # inactives : sans keepalive, le tunnel semble mort jusqu'à ce que la
            # machine émette d'elle-même. C'est au CLIENT de l'entretenir, le
            # serveur ne connaît pas son point de terminaison avant qu'il se
            # présente.
            persistentKeepalive = 25;
          }
          // lib.optionalAttrs (cfg.presharedKeyKey != null) {
            presharedKeyFile = config.sops.secrets.${cfg.presharedKeyKey}.path;
          }
        )
      ];
    };
  };
}
