{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.git;
in
{
  options = {
    userSettings.git = {
      enable = lib.mkEnableOption "Enable git";

      pkgs = myLib.mkPkgsOption { inherit lib config; };
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
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.pkgs.git-graph ];

        programs.git = {
          enable = true;
          package = cfg.pkgs.git;
          settings = {
            user.name = lib.mkIf (cfg.userName != null) cfg.userName;
            user.email = lib.mkIf (cfg.userEmail != null && cfg.userEmailSops == null) cfg.userEmail;

            alias = {
              st = "status";
              co = "checkout";
              br = "branch";
              ci = "commit";
              lg = "!f() { case \"$*\" in *--format*|*\" -f \"*|-f|\"-f \"*|*\" -f\") git-graph -m simple \"$@\" ;; *) git-graph -m simple --format \"$(printf '%%h %%d %%s \\033[1;36m<%%an>\\033[0m \\033[32m(%%ad)\\033[0m')\" \"$@\" ;; esac }; f";
            };

            init.defaultBranch = "main";
            push.autoSetupRemote = true;

            # Évite les commits de fusion de la PR hebdomadaire.
            pull.rebase = true;
            core.pager = "delta";
            interactive.diffFilter = "delta --color-only";

            delta = {
              navigate = true;
              side-by-side = true;
              line-numbers = true;
              syntax-theme = "base16";
              diff-stat = true;
              hunk-header-style = "syntax bold";
            };
          };
          ignores = [
            "*.swp"
          ];
        };
      }

      (lib.mkIf (cfg.userEmailSops != null) {
        assertions = myLib.sops.assertAvailable {
          inherit config;
          optionName = "userSettings.git.userEmailSops";
        };
        sops.secrets.${cfg.userEmailSops} = { };
        sops.templates."git-user-email".content = ''
          [user]
            email = ${config.sops.placeholder.${cfg.userEmailSops}}
        '';
        programs.git.settings.include.path = config.sops.templates."git-user-email".path;
      })
    ]
  );
}
