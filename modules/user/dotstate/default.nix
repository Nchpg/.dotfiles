{
  config,
  lib,
  pkgs-stable,
  ...
}:

let
  cfg = config.userSettings.dotstate;
  shells = config.userSettings.shell;

  dotstate = pkgs-stable.writeShellApplication {
    name = "dotstate";
    runtimeInputs = with pkgs-stable; [
      git
      coreutils
      gnutar
      findutils
      gnused
    ];
    text = builtins.readFile ./dotstate.sh;
  };

  # Shell de premier niveau seulement (SHELL_DEPTH).
  greetPosix = ''
    if [ "''${SHELL_DEPTH:-1}" -le 1 ] && command -v dotstate > /dev/null; then
      dotstate greet
    fi
  '';
in
{
  options.userSettings.dotstate.enable = lib.mkOption {
    type = lib.types.bool;
    default = shells.fish.enable || shells.bash.enable || shells.zsh.enable;
    defaultText = lib.literalExpression "fish, bash ou zsh activé";
    description = "Indicateur d'état de la machine face à sa configuration, affiché à l'ouverture d'un shell.";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ dotstate ];

    programs.fish.interactiveShellInit = lib.mkAfter ''
      function fish_greeting
          test "$SHELL_DEPTH" -le 1; or return
          command -q dotstate; and dotstate greet
      end
    '';
    programs.bash.initExtra = lib.mkAfter greetPosix;
    programs.zsh.initContent = lib.mkAfter greetPosix;

    systemd.user.services.dotstate = {
      Unit.Description = "Mise à jour depuis GitHub pour dotstate";
      Service = {
        Type = "oneshot";
        # Le service ne voit pas les home.sessionVariables : même valeur, même source.
        Environment = [ "MY_FLAKE=${config.home.sessionVariables.MY_FLAKE}" ];
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
