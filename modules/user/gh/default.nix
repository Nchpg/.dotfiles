{ config, lib, ... }:

# GitHub CLI (gh) authentifie par token sops. Comme task-tui genere son
# client_secrets.json, on GENERE ~/.config/gh/hosts.yml a partir du PAT stocke
# dans secrets/secrets.yaml (jamais en clair dans le repo ni le Nix store).
# gh lit directement hosts.yml -> auth disponible dans tous les shells (fish/zsh
# /bash) et pour les outils qui appellent gh (dont Claude Code), sans variable
# d'environnement a propager.
let
  cfg = config.userSettings.gh;
in
{
  options.userSettings.gh = {
    enable = lib.mkEnableOption "GitHub CLI (gh), auth par token sops";

    pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };

    tokenSops = lib.mkOption {
      type = lib.types.str;
      default = "gh/token";
      description = ''
        Nom du secret sops contenant le PAT GitHub (Personal Access Token).
        A renseigner via `sops secrets/secrets.yaml` sous la cle correspondante.
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
    assertions = import ../../../lib/assert-sops-available.nix {
      inherit config;
      optionName = "userSettings.gh";
      need = "a besoin du secret sops (token GitHub)";
    };

    programs.gh = {
      enable = true;
      package = cfg.pkgs.gh;
      settings = {
        git_protocol = cfg.gitProtocol;
      };
    };

    # Le PAT vit dans secrets.yaml ; sops le dechiffre vers un fichier runtime,
    # puis l'injecte dans hosts.yml via le placeholder (le token n'apparait que
    # dans le fichier genere a l'activation, hors store).
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
