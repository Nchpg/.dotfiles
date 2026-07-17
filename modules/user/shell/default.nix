{
  config,
  lib,
  pkgs-unstable,
  devShellNames ? [ ],
  ...
}:

let
  cfg = config.userSettings.shell;

  shells = lib.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./.));

  # Un alias `dev-<name>` par devshell auto-découvert dans devshells/ (cf.
  # flake.nix). `VIRTUAL_ENV=""` évite qu'un venv actif dans le shell courant
  # fuite dans le nouveau `nix develop`.
  devShellAliases = lib.concatMapStringsSep "\n" (
    name: ''alias dev-${name}="VIRTUAL_ENV="" nix develop $MY_FLAKE#${name}"''
  ) devShellNames;
in
{
  options = {
    userSettings.shell = {
      default = lib.mkOption {
        type = lib.types.enum shells;
        default = builtins.head shells;
        description = "Shell by default";
      };
      # Outils CLI de confort dev (lazydocker, lazysql, broot, ncdu, feh) :
      # opt-in explicite par user, découplé de desktopApps. Défaut false → root
      # et guest gardent le strict minimum (cf. common.nix) sans que ça dépende
      # d'un autre module.
      devTools = {
        enable = lib.mkEnableOption "outils CLI de confort dev (lazydocker, lazysql, broot, ncdu, feh)";
      };
      devShellAliases = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Generated `dev-<name>` aliases, one per devshells/*.nix";
      };
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = {
    userSettings.shell.devShellAliases = devShellAliases;

    home.packages =
      with cfg.pkgs;
      [
        # Socle requis par les rc/alias communs (cf. shell/common) : pour tous
        # les users, root et guest compris.
        delta
        file
        eza
        duf
        ripgrep
        fd
        curl
        wget
        gnugrep
      ]
      # Confort dev : opt-in via userSettings.shell.devTools (nchpg), pas pour
      # root/guest qui restent au strict minimum (cf. modules/user/common.nix).
      ++ lib.optionals cfg.devTools.enable [
        ncdu
        broot
        lazydocker
        lazysql
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
      # Visionneuse d'images : inutile pour root/guest (strict minimum).
      feh = {
        enable = cfg.devTools.enable;
        package = cfg.pkgs.feh;
      };
      # git TUI : confort dev (même famille que lazydocker/lazysql), gaté sur
      # devTools — pas pour root/guest.
      lazygit = {
        enable = cfg.devTools.enable;
        package = cfg.pkgs.lazygit;
      };
      # fzf/zoxide : ergonomie du shell interactif (Ctrl-R, z/zi), pas des
      # « outils » — laissés à tous les users, pas gatés sur devTools.
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

    # Pas de bat ici : son thémage est géré par modules/user/bat (polarité
    # déléguée à bat lui-même, target stylix explicitement coupé là-bas).
    # feh/lazygit suivent devTools : on ne thémise pas un programme désactivé.
    stylix.targets = {
      feh.enable = cfg.devTools.enable;
      lazygit.enable = cfg.devTools.enable;
    };

    # ERROR HANDLING
    assertions = [
      {
        assertion = lib.any (shellName: cfg."${shellName}".enable) shells;
        message = "Au moins un shell doit être activé";
      }
      {
        assertion = cfg."${cfg.default}".enable;
        message = "Le shell par défaut \"${cfg.default}\" doit être activé";
      }
    ];
  };
}
