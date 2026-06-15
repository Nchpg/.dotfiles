{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.git;
in {
  options = {
    userSettings.git = {
      enable = lib.mkEnableOption "Enable git";

      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      userName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Nom d'utilisateur pour les commits git.";
        example = "John Doe";
      };

      userEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Adresse e-mail pour les commits git (littérale, en clair dans le repo).";
        example = "john.doe@example.com";
      };

      userEmailSops = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Nom du secret sops contenant l'email git. Si défini, l'email est injecté
          via un include gitconfig généré par sops (jamais en clair dans le repo)
          et prend le pas sur `userEmail`.
        '';
        example = "git/email";
      };
    };
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [
  {

    home.packages = with cfg.pkgs; [
      git-graph
    ];

    programs.git = {
      enable = true;
      package = cfg.pkgs.git;
      # HM 26.05 : aliases/extraConfig/userName/userEmail fusionnés dans `settings`
      # (freeform → sections gitconfig). user.* n'accepte plus null → on ne les
      # définit que s'ils sont renseignés (profils guest/root les laissent vides).
      settings = {
        user.name = lib.mkIf (cfg.userName != null) cfg.userName;
        # L'email littéral n'est posé que si on NE passe PAS par sops.
        user.email = lib.mkIf (cfg.userEmail != null && cfg.userEmailSops == null) cfg.userEmail;

        alias = {
          st = "status";
          co = "checkout";
          br = "branch";
          ci = "commit";
          lg = "!f() { case \"$*\" in *--format*|*-f*) git-graph -m simple \"$@\" ;; *) git-graph -m simple --format \"$(printf '%%h %%d %%s \\033[1;36m<%%an>\\033[0m \\033[32m(%%ad)\\033[0m')\" \"$@\" ;; esac }; f";
        };

        init.defaultBranch = "main";
        push.autoSetupRemote = true;
        core.pager = "delta";
        interactive.diffFilter = "delta --color-only";

        delta = {
          navigate = true;
          side-by-side = true;
          line-numbers = true;
          syntax-theme = "base16-stylix";
          diff-stat = true;
          hunk-header-style = "syntax bold";
        };
      };
      ignores = [
        "*.swp"
      ];
    };
  }

  # Email git via sops : on génère un fragment gitconfig `[user] email = …` et on
  # l'inclut. Le vrai email n'apparaît ni dans le repo ni dans le Nix store.
  (lib.mkIf (cfg.userEmailSops != null) {
    sops.secrets.${cfg.userEmailSops} = { };
    sops.templates."git-user-email".content = ''
      [user]
        email = ${config.sops.placeholder.${cfg.userEmailSops}}
    '';
    programs.git.settings.include.path =
      config.sops.templates."git-user-email".path;
  })
  ]);
}