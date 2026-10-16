{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.dns;
  static = config.systemSettings.network.staticIPv4;
in
{
  options.systemSettings.dns = {
    enable = lib.mkEnableOption "résolveur local dnsmasq (DNS à horizon partagé)";

    overrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "cloud.exemple.fr" = "192.168.1.32";
      };
      description = ''
        Nom vers l'adresse à répondre localement, sous-domaines compris.
      '';
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "9.9.9.9"
      ];
      description = "Résolveurs publics interrogés pour le reste.";
    };

    rebindOkDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vpn.exemple.fr" ];
      description = ''
        Noms (et sous-domaines) autorisés à répondre une adresse privée depuis l'amont.
      '';
    };

    dependentUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "cloudflared-tunnel-<uuid>" ];
      description = ''
        Services systemd (sans `.service`) à démarrer après dnsmasq.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.server.mkInternalPorts config {
        tcp = [ 53 ];
        udp = [ 53 ];
      })

      {
        assertions = [
          {
            assertion = static != null;
            message = "systemSettings.dns exige un adressage statique : un résolveur doit répondre à une adresse qui ne bouge pas.";
          }
        ];

        services.dnsmasq = {
          enable = true;

          alwaysKeepRunning = true;

          settings = {
            # resolved occupe 127.0.0.53/54 ; sans 127.0.0.1 il bascule sans bruit sur ses serveurs de secours.
            listen-address = [
              "127.0.0.1"
              static.address
            ];
            bind-interfaces = true;

            address = lib.mapAttrsToList (name: addr: "/${name}/${addr}") cfg.overrides;

            # `address=` ne réécrit que les A : sans `local=`, les AAAA de Cloudflare fuient.
            local = lib.mapAttrsToList (name: _: "/${name}/") cfg.overrides;

            server = cfg.upstreams;

            # SVCB/HTTPS : l'ECH et l'ipv4hint Cloudflare contredisent le A réécrit (ERR_ECH_FALLBACK_CERTIFICATE_INVALID).
            filter-rr = [
              "64"
              "65"
            ];

            no-resolv = true;

            domain-needed = true;
            bogus-priv = true;

            stop-dns-rebind = true;
            rebind-localhost-ok = true;
            rebind-domain-ok = map (domain: "/${domain}/") cfg.rebindOkDomains;
          };
        };

        systemd.services = {
          dnsmasq = {
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];

            # Reste hors de la fenêtre StartLimitBurst.
            serviceConfig.RestartSec = 5;
          };
        }
        // lib.genAttrs cfg.dependentUnits (_: {
          after = [ "dnsmasq.service" ];
          wants = [ "dnsmasq.service" ];
        });
      }
    ]
  );
}
