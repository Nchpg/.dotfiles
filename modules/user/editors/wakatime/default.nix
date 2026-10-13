{
  config,
  lib,
  myLib,
  ...
}:

# API key dans le dépôt de secrets, ~/.wakatime.cfg généré via sops (jamais
# en clair) : tous les plugins (vim, neovim, vscode) lisent ce même fichier.
let
  cfg = config.userSettings.editors.wakatime;
in
{
  options.userSettings.editors.wakatime = {
    enable = lib.mkEnableOption "WakaTime (suivi du temps de code) dans les editeurs";

    pkgs = myLib.mkPkgsOption { inherit lib config; };

    apiKeySops = lib.mkOption {
      type = lib.types.str;
      default = "wakatime/api_key";
      description = ''
        Nom du secret sops contenant l'API key WakaTime.
        A renseigner via `secrets edit <ce nom>`.
      '';
    };

    apiUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL d'API alternative (instance WakaTime self-hosted / Wakapi). Sinon WakaTime.com.";
      example = "https://wakapi.example.com/api";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = myLib.assertSopsAvailable {
      inherit config;
      optionName = "userSettings.editors.wakatime";
      need = "a besoin du secret sops (API key)";
    };

    # CLI sur le PATH (usage manuel : `wakatime-cli --today`).
    home.packages = [ cfg.pkgs.wakatime-cli ];

    sops.secrets.${cfg.apiKeySops} = { };
    sops.templates."wakatime-cfg" = {
      path = "${config.home.homeDirectory}/.wakatime.cfg";
      content =
        lib.concatStringsSep "\n" (
          [
            "[settings]"
            "api_key = ${config.sops.placeholder.${cfg.apiKeySops}}"
          ]
          ++ lib.optional (cfg.apiUrl != null) "api_url = ${cfg.apiUrl}"
        )
        + "\n";
    };
  };
}
