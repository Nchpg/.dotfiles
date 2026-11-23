{
  config,
  lib,
  pkgs-stable,
  myLib,
  ...
}:

# Le téléphone comme Wiimote pour Dolphin. La PWA est publique (<subdomain>.<domaine>, par le tunnel) :
# les téléphones s'y connectent de n'importe où, sans VPN. Le DSU (UDP) vers Dolphin ne passe que par le
# VPN, pour les PC qui ont le service « wiimote » (vpn-peers.json, page VPN). Jamais par le LAN.
let
  cfg = config.systemSettings.wiimote;
  wireguard = config.systemSettings.vpn.wireguard;
  authelia = config.systemSettings.authelia;

  host = "${cfg.subdomain}.${config.systemSettings.proxy.domain}";

  package = pkgs-stable.buildGoModule {
    pname = "wiimote";
    version = "0.1.0";
    src = ./app;
    vendorHash = "sha256-HEY9Vr7nOO8YKOYjHKlVcdl3MlF0DTcIxqHGt8bQIIM=";
    env.CGO_ENABLED = 0;
    meta.mainProgram = "wiimote";
  };

  pcs = wireguard.sourcesFor "wiimote";
in
{
  options.systemSettings.wiimote = {
    enable = lib.mkEnableOption "la manette Wii sur téléphone (PWA et serveur DSU pour Dolphin)";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "wii";
      description = "Sous-domaine public de la PWA, sous `proxy.domain`.";
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
      description = "Port UDP du serveur DSU, ouvert dans le tunnel aux PC qui ont le service.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.systemSettings.proxy.enable && wireguard.enable && authelia.enable;
        message = "systemSettings.wiimote exige le proxy (PWA), le VPN (DSU vers Dolphin) et Authelia (page de l'hôte).";
      }
    ];

    # Page de l'hôte (/dolphin : invitation, profils, adresse du DSU), ouverte compte par compte.
    systemSettings.authelia.services.wiimote = {
      label = "Wiimote (page de l'hôte)";
      inherit host;
    };
    systemSettings.authelia.rules = [ (authelia.ruleFor "wiimote") ];

    systemSettings.vpn.wireguard.services.wiimote = {
      label = "Wiimote (Dolphin)";
      host = "${wireguard.serverAddress}:${toString cfg.dsuPort} (UDP)";
    };

    # Pas `mkInternalPorts` : il ouvrirait aussi le LAN.
    networking.firewall.extraInputRules = lib.optionalString (pcs != [ ]) ''
      iifname "wg0" ip saddr { ${lib.concatStringsSep ", " pcs} } udp dport ${toString cfg.dsuPort} accept comment "DSU de la manette Wii"
    '';

    systemd.services.wiimote = {
      description = "Manette Wii sur téléphone (PWA et serveur DSU)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        WIIMOTE_LISTEN = "127.0.0.1:${toString cfg.port}";
        WIIMOTE_DSU_PORT = toString cfg.dsuPort;
        WIIMOTE_DSU_HOST = wireguard.serverAddress;
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

    # La manette reste ouverte sans compte : l'application exige le jeton du lien d'invitation.
    services.nginx.virtualHosts.${host} = myLib.server.mkTlsVhost {
      locations = authelia.nginxProtect.locations // {
        "/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          proxyWebsockets = true;
        };
        # L'application n'a pas l'usage du cookie de session Authelia : il ne lui est pas transmis.
        "/dolphin" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          extraConfig = authelia.nginxProtect.extraConfig + ''
            proxy_set_header Cookie "";
          '';
        };
      };
    };

    # Pas de raccourci LAN : à la maison aussi, les téléphones passent par le tunnel.
    # Sonde sur la page de la manette, publique (/dolphin, derrière Authelia, répondrait 302) ; son nom est
    # aussi celui du service sur le dashboard.
    systemSettings.proxy.sites.${host} = {
      public = true;
      lanShortcut = false;
      probes.wiimote = { };
    };

    systemSettings.notify.discord.units = [ "wiimote" ];
  };
}
