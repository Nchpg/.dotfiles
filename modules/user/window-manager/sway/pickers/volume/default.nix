{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.pickers.volume;
  term = config.userSettings.terminal.default;

  termCmd = myLib.mkTerminalCmd {
    inherit lib term;
    title = "ncpamixer";
    exec = "ncpamixer";
    kittyExtraOpts = "-o window_padding_width=20";
  };
in
{
  options.userSettings.windowManager.sway.pickers.volume = {
    # Suit waybar : l'entrée "mixer" du menu volume ouvre ce module.
    enable = lib.mkEnableOption "mixeur audio (ncpamixer dans terminal flottant)" // {
      default = config.userSettings.windowManager.sway.waybar.enable;
    };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkFloatingTuiLauncher {
        name = "volume-mixer";
        scriptBody = "exec ${termCmd}";
        keybind = "$mod+p";
        title = "ncpamixer";
        width = 1200;
        height = 850;
      })
      { home.packages = [ cfg.pkgs.ncpamixer ]; }
    ]
  );
}
