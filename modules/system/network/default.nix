{
  config,
  lib,
  target,
  ...
}:

let
  cfg = config.systemSettings.network;
  static = cfg.staticIPv4;
  hostName = "${target.profile}-${target.host}";
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
      ];

      # Le DHCP global est coupé dans les deux cas : l'adressage vient soit de
      # NetworkManager, soit de systemd-networkd ci-dessous.
      networking.useDHCP = false;
    }

    # NetworkManager gère les interfaces (DHCP inclus).
    (lib.mkIf (static == null) {
      networking.networkmanager.enable = true;
    })

    (lib.mkIf (static != null) {
      networking.networkmanager.enable = false;
      networking.useNetworkd = true;

      systemd.network.networks."10-lan" = {
        matchConfig.Name = static.interface;
        address = [ "${static.address}/${toString static.prefixLength}" ];
        routes = [ { Gateway = static.gateway; } ];
        dns = if static.nameservers == [ ] then [ static.gateway ] else static.nameservers;

        # Sans ça, systemd-networkd-wait-online se contente de n'importe quelle
        # interface configurée (docker0 suffit) et network-online.target est
        # atteinte avant que le LAN soit joignable.
        linkConfig.RequiredForOnline = "routable";
      };
    })
  ];
}
