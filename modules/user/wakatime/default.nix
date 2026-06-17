{ config, lib, ... }:

# WakaTime (suivi du temps de code) pour tous les editeurs. Comme gh/task-tui,
# l'API key vit dans secrets/secrets.yaml et on GENERE ~/.wakatime.cfg via sops
# (jamais en clair dans le repo ni le Nix store). Tous les plugins WakaTime
# (vim, neovim, vscode) lisent ce meme fichier -> une seule source de verite.
#
# Les plugins WakaTime de nixpkgs sont patches pour utiliser le wakatime-cli du
# store, donc aucun telechargement reseau a l'execution.
#
# L'activation des plugins cote editeurs est conditionnee a `wakatime.enable`
# (cf. modules vim/neovim/vscode), pour ne pas tracer si le module est off.
let
  cfg = config.userSettings.wakatime;
in {
  options.userSettings.wakatime = {
    enable = lib.mkEnableOption "WakaTime (suivi du temps de code) dans les editeurs";

    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };

    apiKeySops = lib.mkOption {
      type = lib.types.str;
      default = "wakatime/api_key";
      description = ''
        Nom du secret sops contenant l'API key WakaTime.
        A renseigner via `sops secrets/secrets.yaml`.
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
    # CLI sur le PATH (usage manuel : `wakatime-cli --today`). Les plugins
    # nixpkgs embarquent deja leur propre chemin vers le cli du store.
    home.packages = [ cfg.pkgs.wakatime-cli ];

    sops.secrets.${cfg.apiKeySops} = { };
    sops.templates."wakatime-cfg" = {
      path = "${config.home.homeDirectory}/.wakatime.cfg";
      content = lib.concatStringsSep "\n" ([
        "[settings]"
        "api_key = ${config.sops.placeholder.${cfg.apiKeySops}}"
      ] ++ lib.optional (cfg.apiUrl != null) "api_url = ${cfg.apiUrl}") + "\n";
    };
  };
}
