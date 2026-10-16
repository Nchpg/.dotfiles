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

  shells = lib.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./.));

  # nix develop / nix-shell relancent le shell courant ; pas programs.nix-your-shell (ni bash, ni `-c`).
  nixKeepShell = cfg.pkgs.writeShellScript "nix-keep-shell" ''
    set -euo pipefail
    target=$1
    cmd=$2
    shift 2

    case $cmd in
      nix)
        if [ "''${1:-}" = develop ]; then
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

  # Fonctions et pas alias : un alias n'est pas développé derrière une affectation (dev-<name>).
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
      # $SHELL et pas $0 : `su -s` attend un chemin.
      su = ''sudo su -s "$SHELL"'';
      cat = "bat --paging=never --style=plain";
      diff = "delta";
    }
    // lib.listToAttrs (
      map (
        name: lib.nameValuePair "dev-${name}" "VIRTUAL_ENV= nix develop $MY_FLAKE#${name}"
      ) devShellNames
    );

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
      LS_COLORS = ''$(dircolors -b | sed -n "s/^LS_COLORS='\(.*\)';$/\1/p")'';
      # Le bash de nix-shell garde le prompt du shell appelant.
      NIX_SHELL_PRESERVE_PROMPT = "1";
    };

    programs = {
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
