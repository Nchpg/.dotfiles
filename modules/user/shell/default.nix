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

  # `VIRTUAL_ENV=""` évite qu'un venv actif fuite dans le nouveau `nix develop`.
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
      # Opt-in explicite par user, découplé de desktopApps : root/guest
      # gardent le strict minimum (common.nix).
      devTools = {
        enable = lib.mkEnableOption "outils CLI de confort dev (lazydocker, lazysql, broot, ncdu, feh)";
      };
      devShellAliases = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Generated `dev-<name>` aliases, one per devshells/*.nix";
      };
      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
    };
  };

  config = {
    userSettings.shell.devShellAliases = devShellAliases;

    home.packages =
      with cfg.pkgs;
      [
        # Socle requis par les rc/alias communs (shell/common), tous users.
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
      ++ lib.optionals cfg.devTools.enable [
        ncdu
        broot
        lazydocker
        lazysql
      ];

    home.sessionVariables = {
      # Extrait la chaîne entre quotes de `dircolors -b` (--print-database
      # remplissait avec la base de config, format invalide pour eza/ls).
      LS_COLORS = ''$(dircolors -b | sed -n "s/^LS_COLORS='\(.*\)';$/\1/p")'';
    };

    programs = {
      feh = {
        enable = cfg.devTools.enable;
        package = cfg.pkgs.feh;
      };
      lazygit = {
        enable = cfg.devTools.enable;
        package = cfg.pkgs.lazygit;
      };
      # Ergonomie du shell (Ctrl-R, z/zi), pas des "outils" : pas gatés sur devTools.
      fzf = {
        enable = true;
        package = pkgs-unstable.fzf;
      };
      zoxide = {
        enable = true;
        package = cfg.pkgs.zoxide;
      };
    };

    # Pas de bat ici : thémage géré par modules/user/bat (target stylix
    # explicitement coupé là-bas).
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
