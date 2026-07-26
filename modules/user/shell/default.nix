{
  config,
  lib,
  pkgs-unstable,
  devShellNames ? [ ],
  myLib,
  ...
}:

let
  cfg = config.userSettings.shell;

  # Un sous-dossier ici = un shell, sans exception : le listing EST la liste
  # des valeurs valides de `shell.default`. Ne ranger sous shell/ que de vrais
  # shells — un simple outil CLI y deviendrait une valeur acceptée de
  # `default` et ferait planter les assertions ci-dessous (bat, longtemps
  # `_bat` pour être écarté, vit maintenant dans modules/user/cli).
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
      devShellAliases = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Generated `dev-<name>` aliases, one per devshells/*.nix";
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = {
    userSettings.shell.devShellAliases = devShellAliases;

    # Socle requis par les rc/alias communs (shell/common), tous users. Les
    # outils de confort dev ont chacun leur module (cf. dev-tools.nix).
    home.packages = with cfg.pkgs; [
      delta
      file
      eza
      duf
      ripgrep
      fd
      curl
      wget
      gnugrep
    ];

    home.sessionVariables = {
      # Extrait la chaîne entre quotes de `dircolors -b` (--print-database
      # remplissait avec la base de config, format invalide pour eza/ls).
      LS_COLORS = ''$(dircolors -b | sed -n "s/^LS_COLORS='\(.*\)';$/\1/p")'';
    };

    # Ergonomie du shell lui-même (Ctrl-R, z/zi), donc toujours actifs : ce
    # sont des réglages de shell, pas des programmes qu'on choisit d'installer.
    programs = {
      fzf = {
        enable = true;
        package = pkgs-unstable.fzf;
      };
      zoxide = {
        enable = true;
        package = cfg.pkgs.zoxide;
      };
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
