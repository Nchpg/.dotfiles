{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.datadog;
in
{
  options.systemSettings.datadog = {
    enable = lib.mkEnableOption "agent Datadog (métriques d'infrastructure, offre gratuite)";

    apiKeyKey = lib.mkOption {
      type = lib.types.str;
      default = "datadog/api_key";
      description = "Clé sops de la clé d'API (secrets système, contenu brut).";
    };

    site = lib.mkOption {
      type = lib.types.str;
      default = "datadoghq.eu";
      example = "datadoghq.com";
      description = "Région du compte, en nom de domaine nu (pas une URL).";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Nom du host dans l'interface.";
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "role:serveur" ];
      description = "Étiquettes `clé:valeur` des métriques.";
    };

    dogstatsd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Écouteur DogStatsD (UDP 8125, boucle locale).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasInfix "/" cfg.site) && !(lib.hasInfix ":" cfg.site);
        message = "systemSettings.datadog.site attend un nom de domaine nu (datadoghq.eu), pas une URL — l'agent préfixe cette valeur pour construire ses points d'entrée.";
      }
      {
        assertion = !(lib.any (t: lib.hasPrefix "host:" t) cfg.tags);
        message = "systemSettings.datadog.tags : la clé `host:` est réservée par Datadog, qui la remplit depuis systemSettings.datadog.hostname. Une valeur posée à la main y crée un second host.";
      }
    ];

    sops.secrets.${cfg.apiKeyKey} = {
      mode = "0400";
      owner = "datadog";
      restartUnits = [ "datadog-agent.service" ];
    };

    services.datadog-agent = {
      enable = true;

      apiKeyFile = config.sops.secrets.${cfg.apiKeyKey}.path;

      inherit (cfg) site hostname;

      # null et non [ ] : une liste vide ferait écrire `tags: ""` dans datadog.yaml.
      tags = if cfg.tags == [ ] then null else cfg.tags;

      enableTraceAgent = false;
      enableLiveProcessCollection = false;

      # Bogue nixpkgs : le défaut écrit `use_mount: "false"` (chaîne), que l'agent
      # 7.75 refuse, donc plus aucune métrique disque. À retirer une fois corrigé.
      diskCheck = {
        init_config = { };
        instances = [ { use_mount = false; } ];
      };

      extraConfig = {
        logs_enabled = false;

        # Le défaut de l'agent est true, et le module amont ne l'écrit que si le trace-agent est actif.
        apm_config.enabled = false;

        use_dogstatsd = cfg.dogstatsd;

        # Écrit dans /opt/datadog-agent, absent sous NixOS.
        remote_configuration.enabled = false;
      };
    };

    systemSettings.notify.discord.units = [ "datadog-agent" ];

    systemd.services.datadog-agent = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };
    systemSettings.dns.dependentUnits = [ "datadog-agent" ];
  };
}
