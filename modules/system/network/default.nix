{
  config,
  lib,
  pkgs,
  target,
  ...
}:

let
  cfg = config.systemSettings.network;
  static = cfg.staticIPv4;
  hostName = target.machine;
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
                Motif `Match.Name` de l'interface (`en*` couvre l'ethernet).
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
        Adressage IPv4 statique. `null` = NetworkManager en DHCP. Renseigné : systemd-networkd,
        NetworkManager coupé et pare-feu nftables par interface.
      '';
    };

    systemSettings.network.privateDns = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            hostname = lib.mkOption {
              type = lib.types.str;
              description = "Nom TLS du résolveur, vérifié sur son certificat.";
              example = "dns.adguard-dns.com";
            };

            addresses = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.str;
              description = "Adresses du résolveur (resolved n'en résout pas le nom).";
              example = [ "94.140.14.14" ];
            };
          };
        }
      );
      default = null;
      description = ''
        DNS privé en DNS-over-TLS strict pour toutes les requêtes, à la place du DNS du réseau.
        `null` = DNS fourni par le réseau. Sans repli : un portail captif qui bloque le port 853
        coupe la résolution jusqu'à la connexion au portail. Le service `private-dns` le
        coupe (`systemctl stop`) ou le rétablit sans rebuild.
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
        Motifs `iifname` (nftables) des interfaces par lesquelles un service interne est joignable ;
        vide = ports ouverts globalement. Non vide exige nftables (sinon `extraInputRules` est ignoré).
      '';
    };

    systemSettings.network.forwardRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        iifname "wg0" oifname != "wg0" accept comment "peers vers internet"
      '';
      description = ''
        Règles nftables de la chaîne forward, à la place de `networking.firewall.extraForwardRules`.
        Avec `filterForward`, `networking.nat` ajoute une règle qui ouvrirait tout le LAN aux peers :
        ce module l'écarte par un `mkForce`.
      '';
    };
  };

  config = lib.mkMerge [
    {
      networking.hostName = hostName;

      assertions = [
        {
          assertion = builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" hostName != null;
          message = "networking.hostName \"${hostName}\" invalide (profil/host doivent être en minuscules alphanumériques + tirets, cf. RFC 1123).";
        }
        {
          # Le backend iptables ignore `extraInputRules` sans rien dire.
          assertion = cfg.internalIifnames == [ ] || config.networking.nftables.enable;
          message = "systemSettings.network.internalIifnames est renseigné mais le pare-feu est en iptables : les règles par interface seraient ignorées en silence. Active networking.nftables.enable.";
        }
      ];

      networking.useDHCP = false;

      services.resolved.settings.Resolve = {
        LLMNR = "no";
        MulticastDNS = "no";
      };
    }

    (lib.mkIf (static == null) {
      networking.networkmanager.enable = true;
      networking.modemmanager.enable = false;
    })

    (lib.mkIf (cfg.privateDns != null) (
      let
        dropIn = pkgs.writeText "private-dns.conf" ''
          [Resolve]
          DNS=${
            lib.concatMapStringsSep " " (
              address: "${address}#${cfg.privateDns.hostname}"
            ) cfg.privateDns.addresses
          }
          DNSOverTLS=yes
          # ~. : ces serveurs répondent à tout, avant ceux annoncés par le réseau (DHCP).
          Domains=~.
          # Pas de serveurs de secours en clair si le résolveur privé est injoignable.
          FallbackDNS=
        '';
        dropInPath = "/run/systemd/resolved.conf.d/private-dns.conf";
        reloadResolved = "${pkgs.systemd}/bin/systemctl --no-block reload-or-restart systemd-resolved.service";
      in
      {
        services.resolved.enable = true;
        networking.networkmanager.dns = lib.mkIf (static == null) "systemd-resolved";

        # Basculable sans rebuild (bouton waybar) : start = DNS privé, stop = DNS du réseau.
        # Drop-in dans /run : chaque boot repart sur le DNS privé.
        systemd.services.private-dns = {
          description = "DNS privé (${cfg.privateDns.hostname}) en DNS-over-TLS";
          after = [ "systemd-resolved.service" ];
          wants = [ "systemd-resolved.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = [
              "${pkgs.coreutils}/bin/install -Dm644 ${dropIn} ${dropInPath}"
              reloadResolved
            ];
            ExecStop = [
              "${pkgs.coreutils}/bin/rm -f ${dropInPath}"
              reloadResolved
            ];
          };
        };

        # Les admins basculent private-dns sans mot de passe, et rien d'autre.
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units"
                && action.lookup("unit") == "private-dns.service"
                && subject.isInGroup("wheel")) {
              return polkit.Result.YES;
            }
          });
        '';
      }
    ))

    (lib.mkIf (static != null) {
      networking.networkmanager.enable = false;
      networking.useNetworkd = true;

      systemSettings.network.internalIifnames = [ static.interface ];

      # nftables requis : en iptables FORWARD n'est filtrée par rien (un client VPN atteignait le LAN).
      # Docker et libvirt écrivent en iptables : ordre d'évaluation non garanti, d'où l'avertissement plus bas.
      networking.nftables.enable = true;
      networking.firewall.filterForward = true;

      networking.firewall.extraForwardRules = lib.mkForce cfg.forwardRules;

      # Reverse path strict : les `networks` d'Authelia font confiance à 10.8.0.0/24 ; pas de "loose" sans les retirer.
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

        # Sans RA pas d'IPv6 globale : sans NAT, tout port ouvert serait joignable d'internet.
        # Si l'IPv6 sortante devient nécessaire, rouvrir les RA et ouvrir 443, 53 et SSH par interface.
        networkConfig.IPv6AcceptRA = false;

        # Sinon network-online est atteint dès que docker0 est configuré.
        linkConfig.RequiredForOnline = "routable";
      };
    })
  ];
}
