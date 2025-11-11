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
        lg = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
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