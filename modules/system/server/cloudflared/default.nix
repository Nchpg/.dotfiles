{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.cloudflared;
in
{
  options.systemSettings.cloudflared = {
    enable = lib.mkEnableOption "tunnel Cloudflare (accès web sans port ouvert)";

    tunnelId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "6ff42ae2-765d-4adf-8112-31c55c1551ef";
      description = ''
        UUID du tunnel, tel que renvoyé par `cloudflared tunnel create <nom>`.
      '';
    };

    metricsAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1:2000";
      description = ''
        Adresse `hôte:port` de la page `/metrics` du démon (fermée si `null`).
      '';
    };

    ingress = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "cloud.exemple.fr" = "https://127.0.0.1:443";
      };
      description = ''
        Nom public vers le service local qui le sert ; repris en SNI, il doit correspondre à un vhost nginx.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tunnelId != null;
        message = "systemSettings.cloudflared.tunnelId n'est pas renseigné — crée le tunnel avec `cloudflared tunnel create` et reporte l'UUID qu'il affiche.";
      }
      {
        assertion = cfg.ingress != { };
        message = "systemSettings.cloudflared.ingress est vide : le tunnel monterait sans rien router.";
      }
    ];

    # Pas d'owner : le module amont passe le fichier par LoadCredential.
    # restartUnits : cloudflared ne recharge pas ses credentials (530 silencieux).
    sops.secrets."cloudflared/credentials" = {
      restartUnits = lib.optional (cfg.tunnelId != null) "cloudflared-tunnel-${cfg.tunnelId}.service";
    };

    # Le tunnel abandonne si la résolution de l'edge échoue au boot : après dnsmasq.
    systemSettings = lib.mkIf (cfg.tunnelId != null) {
      notify.discord.units = [ "cloudflared-tunnel-${cfg.tunnelId}" ];
      dns.dependentUnits = [ "cloudflared-tunnel-${cfg.tunnelId}" ];
    };

    # Le module amont lance le binaire par son chemin du store sans l'installer :
    # même paquet que le démon pour `cloudflared tunnel list/info…`.
    environment.systemPackages = [ config.services.cloudflared.package ];

    # Par l'environnement : le module amont fixe son ExecStart.
    systemd.services = lib.mkIf (cfg.tunnelId != null && cfg.metricsAddress != null) {
      "cloudflared-tunnel-${cfg.tunnelId}".environment.TUNNEL_METRICS = cfg.metricsAddress;
    };

    services.cloudflared = {
      enable = true;
      # Unstable : l'edge Cloudflare évolue vite, les versions de 26.05 prennent du retard.
      package = pkgs-unstable.cloudflared;

      # Un nom d'attribut s'évalue avant les assertions.
      tunnels = lib.optionalAttrs (cfg.tunnelId != null) {
        ${cfg.tunnelId} = {
          credentialsFile = config.sops.secrets."cloudflared/credentials".path;

          ingress = lib.mapAttrs (hostname: service: {
            inherit service;

            originRequest = {
              originServerName = hostname;

              # Empêche d'annoncer le nom interne pour tomber sur la règle Authelia sans authentification.
              httpHostHeader = hostname;
            };
          }) cfg.ingress;

          default = "http_status:404";
        };
      };
    };
  };
}
