{
  config,
  lib,
  ...
}:

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
        Adresse de cet appareil dans le tunnel, avec son préfixe ; doit correspondre à
        l'`AllowedIPs` du peer côté serveur (un /32).
      '';
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "vpn.exemple.fr:51820";
      description = "Point de terminaison public du serveur (hôte:port), résolu avant que le tunnel existe.";
    };

    serverPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Clé publique du serveur (`sudo wg show wg0 public-key`), à mettre à jour si elle change.";
    };

    privateKeyKey = lib.mkOption {
      type = lib.types.str;
      example = "wireguard/gram_private_key";
      description = ''
        Clé sops de la clé privée de cet appareil (brute, `wg genkey`). Sans défaut :
        `networking.hostName` varie avec la cible.
      '';
    };

    presharedKeyKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wireguard/gram_preshared_key";
      description = ''
        Clé sops de la clé pré-partagée, identique au `presharedKeyKey` du peer côté serveur. `null` désactive.
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
        Résolveurs employés pendant que le tunnel est monté. Vide : résolveur du réseau visité,
        les noms internes ne résolvent pas.
      '';
    };

    allowedIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.8.0.0/24" ];
      description = ''
        Destinations routées dans le tunnel (CIDR). Sans défaut : `0.0.0.0/0` casserait à la maison,
        où le préfixe est déjà connecté sur le WiFi. Valeur du parc : `10.8.0.0/24`.
      '';
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Monte le tunnel au démarrage. Bascule : `systemctl start|stop wg-quick-wg0`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Une liste vide serait acceptée : poignée de main réussie, aucun paquet.
        assertion = cfg.allowedIPs != [ ];
        message = "systemSettings.vpn.client.allowedIPs est vide : le tunnel monterait sans router quoi que ce soit dedans. Mets-y le sous-réseau du tunnel (10.8.0.0/24), pas 0.0.0.0/0 — cf. la description de l'option.";
      }
    ];

    # restartUnits : wg-quick ne relit les fichiers qu'au montage.
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
