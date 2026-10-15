{
  config,
  lib,
  myLib,
  ...
}:

# hosts.yml généré depuis le PAT stocké dans le dépôt de secrets (jamais en
# clair dans le repo ni le store) : gh le lit directement, auth disponible
# dans tous les shells sans variable d'environnement à propager.
let
  cfg = config.userSettings.git.gh;
in
{
  options.userSettings.git.gh = {
    enable = lib.mkEnableOption "GitHub CLI (gh), auth par token sops";

    pkgs = myLib.mkPkgsOption { inherit lib config; };

    tokenSops = lib.mkOption {
      type = lib.types.str;
      default = "gh/token";
      description = ''
        Nom du secret sops contenant le PAT GitHub (Personal Access Token).
        A renseigner via `secrets edit <ce nom>`.
      '';
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Nom d'utilisateur GitHub (champ informatif de hosts.yml).";
      example = "nchpg";
    };

    gitProtocol = lib.mkOption {
      type = lib.types.enum [
        "https"
        "ssh"
      ];
      default = "https";
      description = "Protocole git utilise par gh pour cloner/pousser.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = myLib.sops.assertAvailable {
      inherit config;
      optionName = "userSettings.git.gh";
      need = "a besoin du secret sops (token GitHub)";
    };

    programs.gh = {
      enable = true;
      package = cfg.pkgs.gh;
      settings = {
        git_protocol = cfg.gitProtocol;
      };
    };

    sops.secrets.${cfg.tokenSops} = { };
    sops.templates."gh-hosts" = {
      path = "${config.home.homeDirectory}/.config/gh/hosts.yml";
      content =
        lib.concatStringsSep "\n" (
          [
            "github.com:"
            "    oauth_token: ${config.sops.placeholder.${cfg.tokenSops}}"
            "    git_protocol: ${cfg.gitProtocol}"
          ]
          ++ lib.optional (cfg.user != null) "    user: ${cfg.user}"
        )
        + "\n";
    };
  };
}
