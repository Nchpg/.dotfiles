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
        description = "Adresse e-mail pour les commits git.";
        example = "john.doe@example.com";
      };
    };
  };
  config = lib.mkIf cfg.enable {

    home.packages = with cfg.pkgs; [
      git-graph
    ];

    programs.git = {
      enable = true;
      package = cfg.pkgs.git;
      userName = cfg.userName;
      userEmail = cfg.userEmail;
      aliases = {
        st = "status";
        co = "checkout";
        br = "branch";
        ci = "commit";
        #lg = "!f() { git-graph -m simple --format \"$(printf '%%h %%d %%s \\033[1;36m<%%an>\\033[0m \\033[32m(%%ad)\\033[0m')\" \"$@\"; }; f";
        lg = "!f() { case \"$*\" in *--format*|*-f*) git-graph -m simple \"$@\" ;; *) git-graph -m simple --format \"$(printf '%%h %%d %%s \\033[1;36m<%%an>\\033[0m \\033[32m(%%ad)\\033[0m')\" \"$@\" ;; esac }; f";
      };
      extraConfig = {
        init = {
          defaultBranch = "main";
        };
        push = {
          autoSetupRemote = true;
        };
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
  };
}