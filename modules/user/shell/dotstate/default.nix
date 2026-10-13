{
  config,
  lib,
  pkgs-stable,
  ...
}:

# INDICATEUR D'ÉTAT : cette machine correspond-elle à sa configuration ? Ce qui
# tourne face au dépôt local, le dépôt face à GitHub, les secrets, un
# redémarrage en attente (cf. dotstate.sh).
#
# Affiché à l'ouverture d'un shell, et seulement s'il y a un écart : donc aussi
# en SSH, où chaque machine montre le sien. Rien dans le prompt.
let
  cfg = config.userSettings.shell.dotstate;
  shells = config.userSettings.shell;

  dotstate = pkgs-stable.writeShellApplication {
    name = "dotstate";
    # `timeout`, `mktemp`, `readlink`, `uname`, `date`, `sha256sum` :
    # coreutils ; `tar`, `find`/`xargs`, `sed` pour l'empreinte du contenu.
    runtimeInputs = with pkgs-stable; [
      git
      coreutils
      gnutar
      findutils
      gnused
    ];
    text = builtins.readFile ./dotstate.sh;
  };

  # Seulement dans un shell de premier niveau : pas à chaque `nix develop` ou
  # shell imbriqué. VS Code ouvre son terminal un niveau plus bas, comme le
  # compte déjà le prompt.
  greetPosix = ''
    __dotstate_depth=$SHLVL
    [ "$TERM_PROGRAM" = vscode ] && __dotstate_depth=$((SHLVL - 1))
    if [ "''${__dotstate_depth:-1}" -le 1 ] && command -v dotstate > /dev/null; then
      dotstate greet
    fi
    unset __dotstate_depth
  '';
in
{
  options.userSettings.shell.dotstate.enable = lib.mkOption {
    type = lib.types.bool;
    default = shells.fish.enable || shells.bash.enable || shells.zsh.enable;
    defaultText = lib.literalExpression "fish, bash ou zsh activé";
    description = "Indicateur d'état de la machine face à sa configuration, affiché à l'ouverture d'un shell.";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ dotstate ];

    # fish : remplace le fish_greeting vide de la config fish (mkAfter).
    programs.fish.interactiveShellInit = lib.mkAfter ''
      function fish_greeting
          set -l depth $SHLVL
          test "$TERM_PROGRAM" = vscode; and set depth (math $depth - 1)
          test "$depth" -le 1; or return
          command -q dotstate; and dotstate greet
      end
    '';
    # bash : initExtra, la partie interactive du .bashrc.
    programs.bash.initExtra = lib.mkAfter greetPosix;
    programs.zsh.initContent = lib.mkAfter greetPosix;

    # Fetch de GitHub à intervalle régulier : la seule partie lente, faite en
    # arrière-plan pour que l'ouverture d'un shell reste instantanée.
    systemd.user.services.dotstate = {
      Unit.Description = "Mise à jour depuis GitHub pour dotstate";
      Service = {
        Type = "oneshot";
        Environment = [ "MY_FLAKE=${config.home.homeDirectory}/.dotfiles" ];
        ExecStart = "${lib.getExe dotstate} fetch";
      };
    };
    systemd.user.timers.dotstate = {
      Unit.Description = "Mise à jour régulière depuis GitHub pour dotstate";
      Timer = {
        OnStartupSec = "1min";
        OnUnitActiveSec = "15min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
