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

  # `nix develop` / `nix-shell` relancent le shell COURANT au lieu de bash
  # (celui de `nix develop` par défaut) ou du shell de login (`$SHELL`, celui
  # de nix-shell). Une seule implémentation pour les trois shells : chacun
  # n'a qu'à appeler ce script avec son nom (cf. bash/zsh/fish).
  #
  # Pas `programs.nix-your-shell` de home-manager : il ne gère ni bash ni le
  # `--command`/`-c` déjà passé, et ajoute un paquet pour trois `case`.
  nixKeepShell = cfg.pkgs.writeShellScript "nix-keep-shell" ''
    set -euo pipefail
    # $1 : shell à relancer ; $2 : nix ou nix-shell ; la suite : ses arguments.
    target=$1
    cmd=$2
    shift 2

    case $cmd in
      nix)
        if [ "''${1:-}" = develop ]; then
          # `-c` est l'abréviation de `--command` : sans ce test, `nix develop
          # -c cmd` se voyait ajouter un second `--command` et échouait.
          for arg in "$@"; do
            case $arg in --command | -c) exec nix "$@" ;; esac
          done
          exec nix "$@" --command "$target"
        fi
        exec nix "$@"
        ;;
      nix-shell)
        for arg in "$@"; do
          case $arg in --run | --command) exec nix-shell "$@" ;; esac
        done
        exec nix-shell "$@" --run "exec $target"
        ;;
    esac
  '';

  # Fonctions (et pas alias) : un alias n'est pas développé derrière une
  # affectation (`VIRTUAL_ENV= nix develop`, cf. dev-<name>).
  posixNixWrappers = shell: ''
    nix() { ${nixKeepShell} ${shell} nix "$@"; }
    nix-shell() { ${nixKeepShell} ${shell} nix-shell "$@"; }
  '';
in
{
  options = {
    userSettings.shell = {
      default = lib.mkOption {
        type = lib.types.enum shells;
        default = builtins.head shells;
        description = "Shell by default";
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = {
    # Communs aux trois shells (home-manager les écrit dans chaque rc ; sous
    # fish, `alias` définit une fonction).
    home.shellAliases = {
      ls = "eza --icons --sort=name --group-directories-first --color=always";
      ll = "eza -lh --icons --sort=name --group-directories-first --color=always";
      la = "eza -lha --icons --sort=name --group-directories-first --color=always";
      tree = "eza --tree --icons --sort=name --color=always";
      df = "duf";

      mpv = "mpv --keep-open=yes";
      mpvt = "mpv --keep-open=yes --vo=kitty";

      grep = "grep --color=auto";
      fgrep = "fgrep --color=auto";
      egrep = "egrep --color=auto";

      cls = "clear";
      # `$SHELL` et pas `$0` : `su -s` attend un CHEMIN de shell, alors que `$0`
      # vaut un simple nom ("fish", "bash" — fish le pose lui-même via
      # `export 0=fish`), que su ne sait pas résoudre. $SHELL porte le chemin
      # absolu du shell de login.
      su = ''sudo su -s "$SHELL"'';
      cat = "bat --paging=never --style=plain";
      # Options (side-by-side, numéros, thème 'base16' qui suit le thème stylix
      # actif) : lues par delta dans la section [delta] de la config git
      # (modules/user/git), la même que pour `git diff`.
      diff = "delta";
    }
    # Un `dev-<name>` par devshells/*.nix. `VIRTUAL_ENV=` évite qu'un venv
    # actif fuite dans le nouveau `nix develop`.
    // lib.listToAttrs (
      map (
        name: lib.nameValuePair "dev-${name}" "VIRTUAL_ENV= nix develop $MY_FLAKE#${name}"
      ) devShellNames
    );

    # Socle requis par les alias et rc communs, tous users. Les outils de
    # confort dev ont chacun leur module (cf. modules/user/dev).
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
      # Le bash de nix-shell garde le prompt du shell appelant.
      NIX_SHELL_PRESERVE_PROMPT = "1";
    };

    # Ergonomie du shell lui-même (Ctrl-R, z/zi), donc toujours actifs : ce
    # sont des réglages de shell, pas des programmes qu'on choisit d'installer.
    programs = {
      # `man` = batman sous bash/zsh ; fish a sa propre fonction `man`
      # (sélecteur fzf sans argument, cf. fish/fzf_wrapper.fish).
      bash.shellAliases.man = "batman";
      zsh.shellAliases.man = "batman";

      bash.initExtra = posixNixWrappers "bash";
      zsh.initContent = posixNixWrappers "zsh";
      fish.functions = {
        nix = "${nixKeepShell} fish nix $argv";
        nix-shell = "${nixKeepShell} fish nix-shell $argv";
      };

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
