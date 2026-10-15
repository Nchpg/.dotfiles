{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.terminal.alacritty;
in
{
  options = {
    userSettings.terminal.alacritty = {
      enable = lib.mkEnableOption "Enable alacritty terminal";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      shell = myLib.desktop.mkTerminalShellOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.alacritty = {
      enable = true;
      package = cfg.pkgs.alacritty;

      settings = {
        terminal.shell.program = myLib.desktop.mkTerminalShellBin {
          inherit (cfg) pkgs shell;
        };
      };
    };

    stylix.targets.alacritty.enable = true;
  };
}
