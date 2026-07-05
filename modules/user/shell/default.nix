{ config, lib, pkgs-stable, pkgs-unstable, ... }:

let
  cfg = config.userSettings.shell;
  
  shells = lib.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./.));
in {
  options = {
    userSettings.shell = {
      default = lib.mkOption {
          type = lib.types.enum shells;
          default = builtins.head shells;
          description = "Shell by default";
      };
      list = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          readOnly = true;
          description = "List of available shells";
      };
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = {
    userSettings.shell.list = shells;

    home.packages = with cfg.pkgs; [
      delta
      file
      eza
      duf
      ripgrep
      fd
      curl
      wget
      ncdu
      broot
      lazydocker
      lazysql
      gnugrep
    ];

    home.sessionVariables = {
      # `dircolors -b` sort `LS_COLORS='…'; export LS_COLORS` : on extrait la
      # chaîne entre quotes. (L'ancien `--print-database` remplissait la
      # variable avec la BASE DE CONFIG, format invalide → eza/ls retombaient
      # sur leurs couleurs par défaut.) La valeur est posée verbatim dans
      # hm-session-vars.sh, donc la substitution s'exécute à l'init du shell.
      LS_COLORS = ''$(dircolors -b | sed -n "s/^LS_COLORS='\(.*\)';$/\1/p")'';
    };

    programs = {
      # btop est géré par son propre module (modules/user/btop) pour permettre
      # l'override du support GPU Intel xe.
      feh = {
        enable = true;
        package = cfg.pkgs.feh;
      };
      lazygit = {
        enable = true;
        package = cfg.pkgs.lazygit;
      };
      fzf = {
        enable = true;
        package = pkgs-unstable.fzf;
      };
      zoxide = {
        enable = true;
        package = cfg.pkgs.zoxide;
        # Intégration shell (fish/bash/zsh) activée automatiquement.
        # `z <terme>` saute vers un dossier fréquent, `zi` ouvre un sélecteur fzf.
      };
    };

    stylix.targets = {
      bat.enable = true;
      feh.enable = true;
      lazygit.enable = true;
    };

    # ERROR HANDLING
    assertions = [
      {
        assertion = lib.any 
          (shellName: cfg."${shellName}".enable) 
          shells;
        message = "Au moins un shell doit être activé";
      }
      {
        assertion = cfg."${cfg.default}".enable;
        message = "Le shell par défaut \"${cfg.default}\" doit être activé";
      }
    ];
  };
}