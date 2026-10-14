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

        # delta (core.pager/diffFilter plus bas) : fourni par le socle de
        # modules/user/shell, toujours actif.
        home.packages = [ cfg.pkgs.git-graph ];

        programs.git = {
          enable = true;
          package = cfg.pkgs.git;
          # HM 26.05 : user.* n'accepte plus null -> défini seulement si renseigné
          # (profils guest/root le laissent vide).
          settings = {
            user.name = lib.mkIf (cfg.userName != null) cfg.userName;
            user.email = lib.mkIf (cfg.userEmail != null && cfg.userEmailSops == null) cfg.userEmail;

            alias = {
              st = "status";
              co = "checkout";
              br = "branch";
              ci = "commit";
              # `-f` ne matche qu'en argument exact : le motif `*-f*` attrapait
              # aussi --first-parent, --follow, ou un fichier "mon-fichier.c".
              lg = "!f() { case \"$*\" in *--format*|*\" -f \"*|-f|\"-f \"*|*\" -f\") git-graph -m simple \"$@\" ;; *) git-graph -m simple --format \"$(printf '%%h %%d %%s \\033[1;36m<%%an>\\033[0m \\033[32m(%%ad)\\033[0m')\" \"$@\" ;; esac }; f";
            };

            init.defaultBranch = "main";
            push.autoSetupRemote = true;

            # `git pull` rebase au lieu de fusionner. Évite les commits de fusion
            # parasites quand la branche distante a bougé pendant qu'on
            # travaillait — cas courant avec la PR hebdomadaire de weekly-update,
            # qui pousse sur une branche qu'on peut avoir en local.
            #
            # Corollaire : un `pull` sur un travail non commité s'interrompt au
            # lieu de fusionner. C'est voulu, mais ça surprend la première fois.
            pull.rebase = true;
            core.pager = "delta";
            interactive.diffFilter = "delta --color-only";

            # Lu aussi par l'alias `diff` (delta seul, cf. modules/user/shell).
            delta = {
              navigate = true;
              side-by-side = true;
              line-numbers = true;
              # Colore avec les 16 ANSI du terminal -> suit le thème stylix actif.
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

      # Fragment gitconfig généré via sops : l'email n'apparaît ni dans le
      # repo ni dans le store.
      (lib.mkIf (cfg.userEmailSops != null) {
        assertions = myLib.assertSopsAvailable {
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
