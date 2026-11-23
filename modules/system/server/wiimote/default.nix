{
  config,
  lib,
  myLib,
  pkgs-stable,
  ...
}:

# Le téléphone comme Wiimote pour Dolphin : PWA sur <subdomain>.<domaine>, en LAN seulement, dont l'état
# est rediffusé en DSU (UDP) à tout Dolphin du réseau. Rien à installer sur les PC (page /dolphin).
let
  cfg = config.systemSettings.wiimote;
  static = config.systemSettings.network.staticIPv4;

  host = "${cfg.subdomain}.${config.systemSettings.proxy.domain}";

  package = pkgs-stable.buildGoModule {
    pname = "wiimote";
    version = "0.1.0";
    src = ./app;
    vendorHash = "sha256-LIYnmXs6gbwuVDr0Utny5GY0FCgPKgwjwOzYirQ0MFM=";
    env.CGO_ENABLED = 0;
    meta.mainProgram = "wiimote";
  };
in
{
  options.systemSettings.wiimote = {
    enable = lib.mkEnableOption "la manette Wii sur téléphone (PWA et serveur DSU pour Dolphin)";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "wii";
      description = "Sous-domaine de la PWA, sous `proxy.domain`, résolu sur le LAN seulement.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8097;
      description = "Port de bouclage de la PWA, derrière nginx.";
    };

    dsuPort = lib.mkOption {
      type = lib.types.port;
      # Port par défaut des serveurs DSU, celui que Dolphin propose.
      default = 26760;
      description = "Port UDP du serveur DSU, ouvert sur le LAN.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.server.mkInternalPorts config { udp = [ cfg.dsuPort ]; })

      {
        assertions = [
          {
            assertion = config.systemSettings.proxy.enable && static != null;
            message = "systemSettings.wiimote exige le proxy et une adresse statique (celle que Dolphin interroge).";
          }
        ];

        systemd.services.wiimote = {
          description = "Manette Wii sur téléphone (PWA et serveur DSU)";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          environment = {
            WIIMOTE_LISTEN = "127.0.0.1:${toString cfg.port}";
            WIIMOTE_DSU_PORT = toString cfg.dsuPort;
            WIIMOTE_DSU_HOST = static.address;
          };
          serviceConfig = {
            ExecStart = lib.getExe package;
            DynamicUser = true;
            Restart = "on-failure";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            SystemCallArchitectures = "native";
            CapabilityBoundingSet = [ "" ];
          };
        };

        services.nginx.virtualHosts.${host} = myLib.server.mkTlsVhost {
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString cfg.port}";
            proxyWebsockets = true;
          };
        };

        # Pas de route dans le tunnel : la latence de Cloudflare gênerait le jeu, et personne hors du LAN
        # ne doit piloter la manette. Le résolveur local répond l'adresse du LAN.
        systemSettings.proxy.sites.${host} = {
          public = false;
          lanShortcut = true;
        };

        systemSettings.notify.discord.units = [ "wiimote" ];
      }
    ]
  );
}
