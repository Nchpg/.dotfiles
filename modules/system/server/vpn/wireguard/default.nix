{
  config,
  lib,
  myLib,
  pkgs-stable,
  inputs,
  ...
}:

let
  cfg = config.systemSettings.vpn.wireguard;
  static = config.systemSettings.network.staticIPv4;

  privateKeyPath = config.sops.secrets.${cfg.privateKeyKey}.path;

  # Appareils ajoutés par le dashboard (peersFile) : chacun a SA clé pré-partagée, rangée sous un
  # nom fixe ; elle doit exister dans les secrets, sinon l'évaluation s'arrête (cf. assertions).
  # Un appareil inscrit sans elle n'est donc jamais autorisé.
  pskKeyOf = name: "wireguard/${name}_preshared_key";
  # Services réservés qu'un appareil peut recevoir (cf. `services`) ; les sites, eux, sont dans apps.json.
  knownServices = [
    "dashboard"
    "vaultwarden"
  ];
  # Rangés par adresse : l'ordre des [WireGuardPeer] reste celui d'avant le fichier (et du tunnel).
  lastOctet = p: lib.toInt (lib.last (lib.splitString "." p.address));
  filePeers =
    if cfg.peersFile == null then
      [ ]
    else
      lib.sort (a: b: lastOctet a < lastOctet b) (
        lib.mapAttrsToList (name: p: {
          inherit name;
          inherit (p) publicKey address;
          services = p.services or [ ];
          # Vaultwarden lit `trustedSources` : ses appareils sont ceux qui ont ce service.
          trusted = lib.elem "vaultwarden" (p.services or [ ]);
          presharedKeyKey = pskKeyOf name;
        }) (lib.importJSON cfg.peersFile)
      );
  # /24 seulement : les trois premiers octets du sous-réseau, que toute adresse d'appareil partage.
  subnetPrefix = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." cfg.subnet));
  badFilePeers = lib.filter (
    p:
    builtins.match "[a-z0-9_]{1,24}" p.name == null
    || builtins.match "[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=" p.publicKey == null
    || builtins.match "${lib.escapeRegex subnetPrefix}\\.([0-9]{1,3})" p.address == null
    || lib.subtractLists knownServices p.services != [ ]
  ) filePeers;
  missingPsk = lib.filter (
    p: !builtins.pathExists "${inputs.secrets}/${p.presharedKeyKey}.yaml"
  ) filePeers;

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
        Nom public (ou IP publique) inscrit comme `Endpoint` dans les profils clients.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = ''
        Port UDP, à rediriger sur la box.
      '';
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "10.8.0.0/24";
      description = ''
        Plage du tunnel (CIDR), disjointe du LAN.
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
        Résolveurs inscrits dans les profils clients, dans l'ordre.
        Lu seulement à la fabrication d'un profil.
      '';
    };

    allowedIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "0.0.0.0/0"
        "::/0"
      ];
      description = ''
        Routes poussées aux clients (défaut : tunnel complet). `::/0` évite que
        l'IPv6 d'un client double pile sorte hors du tunnel.
      '';
    };

    privateKeyKey = lib.mkOption {
      type = lib.types.str;
      default = "wireguard/server_private_key";
      description = "Clé sops de la clé privée du serveur.";
    };

    peersFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./vpn-peers.json";
      description = ''
        Appareils inscrits par le dashboard (`{"<nom>": {"publicKey", "address", "trusted"}}`), en plus de
        `peers`. Chacun exige le secret `wireguard/<nom>_preshared_key`.
      '';
    };

    peers = lib.mkOption {
      default = [ ];
      description = "Appareils autorisés, par clé publique.";
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
              description = "Nom de l'appareil, documentaire.";
            };

            publicKey = lib.mkOption {
              type = lib.types.str;
              description = "Clé publique de l'appareil, telle que produite par `wg-new-peer`.";
            };

            address = lib.mkOption {
              type = lib.types.str;
              example = "10.8.0.2";
              description = "Adresse unique de l'appareil dans le tunnel.";
            };

            presharedKeyKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "wireguard/gram_preshared_key";
              description = ''
                Clé sops de la clé pré-partagée de cet appareil. `null` désactive.
              '';
            };

            trusted = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Appareil de confiance : inclus dans `trustedSources`.
              '';
            };

            services = lib.mkOption {
              type = lib.types.listOf (lib.types.enum knownServices);
              default = [ ];
              description = ''
                Services réservés auxquels l'appareil a accès : `dashboard` (systemSettings.admin.devices
                le reprend) et `vaultwarden` (il fait l'appareil `trusted`).
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
        Laisse les peers ressortir vers internet par la maison, destinations privées exclues.
      '';
    };

    trustedSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = map (p: "${p.address}/32") (lib.filter (p: p.trusted) cfg.peers);
      defaultText = lib.literalExpression "les adresses en /32 des peers `trusted`";
      description = "Adresses CIDR des peers `trusted`, à reprendre dans un `allowedNetworks`.";
    };

    selfSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default = if static != null then "${static.address}/32" else null;
      defaultText = lib.literalExpression "l'adresse du LAN de ce host, en /32";
      description = ''
        Source sous laquelle ce host se voit quand il vise sa propre adresse de
        tunnel (le masquerade réécrit sa source en adresse du LAN).
      '';
    };

    peerLanAccess = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.1.20" ];
      description = ''
        Adresses ou préfixes du LAN qu'un peer peut joindre à travers ce host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemSettings.vpn.wireguard.peers = filePeers;

    assertions = [
      {
        assertion = badFilePeers == [ ];
        message = "systemSettings.vpn.wireguard.peersFile : entrée invalide pour ${
          lib.concatMapStringsSep ", " (p: p.name) badFilePeers
        } (nom en [a-z0-9_], clé publique WireGuard, adresse dans ${cfg.subnet}).";
      }
      {
        assertion = missingPsk == [ ];
        message = lib.concatMapStringsSep "\n" (
          p:
          "Appareil VPN « ${p.name} » inscrit mais sans clé pré-partagée : `secrets edit ${p.presharedKeyKey}` (valeur donnée par le dashboard), puis relance."
        ) missingPsk;
      }
      {
        assertion = cfg.host != null;
        message = "systemSettings.vpn.wireguard.host n'est pas renseigné — les configurations clientes pointeraient dans le vide. Mets-y le nom public (ou l'IP publique) de ta connexion.";
      }
      {
        assertion = static != null;
        message = "systemSettings.vpn.wireguard exige un adressage statique (systemSettings.network.staticIPv4) : le port UDP doit être redirigé vers une adresse qui ne bouge pas.";
      }
      {
        # WireGuard route vers le dernier peer déclaré, l'autre cesse de marcher.
        assertion = lib.length (lib.unique peerAddresses) == lib.length peerAddresses;
        message = "systemSettings.vpn.wireguard.peers : deux appareils partagent la même adresse. Chacune doit être unique dans le tunnel.";
      }
      {
        assertion = !lib.elem cfg.serverAddress peerAddresses;
        message = "systemSettings.vpn.wireguard.peers : un appareil utilise ${cfg.serverAddress}, qui est l'adresse du serveur (serverAddress).";
      }
      {
        # dnsmasq n'écoute que sur la boucle locale et l'adresse du LAN.
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

    # restartUnits : networkd lit ces fichiers au montage de l'interface seulement.
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

        # AllowedIPs filtre aussi l'entrée : un peer ne peut pas émettre sous l'adresse d'un autre.
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

        networkConfig.IPv6AcceptRA = false;
      };
    };

    systemSettings.network.internalIifnames = [ "wg0" ];

    # `oifname != "wg0"` isole les peers entre eux. Via `forwardRules` : la règle
    # ouverte de `networking.nat` rouvrirait ce qu'on ferme.
    systemSettings.network.forwardRules =
      lib.optionalString cfg.peerInternetAccess ''
        iifname "wg0" oifname != "wg0" ip daddr != { ${lib.concatStringsSep ", " myLib.server.nonRoutableIPv4} } accept comment "peers vers internet"
      ''
      + lib.optionalString (cfg.peerLanAccess != [ ]) ''
        iifname "wg0" ip daddr { ${lib.concatStringsSep ", " cfg.peerLanAccess} } accept comment "peers vers le LAN, liste explicite"
      '';

    # Piège : le trafic que ce host émet vers sa propre adresse de tunnel traverse
    # POSTROUTING et sa source devient l'adresse du LAN (cf. `selfSource`).
    # `internalIPs` : la carte est nommée par un motif (`en*`) inutilisable en règle NAT.
    networking.nat = {
      enable = true;
      internalIPs = [ cfg.subnet ];
    };

    # Ouvert globalement, pas via mkInternalPorts.
    networking.firewall.allowedUDPPorts = [ cfg.port ];

    environment.systemPackages = [
      pkgs-stable.wireguard-tools
      newPeer
    ];
  };
}
