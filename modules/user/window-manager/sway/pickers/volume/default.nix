{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.pickers.volume;
in
{
  options.userSettings.windowManager.sway.pickers.volume = {
    enable = lib.mkEnableOption "mixeur audio (ncpamixer dans terminal flottant)" // {
      default = config.userSettings.windowManager.sway.waybar.enable;
    };
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.desktop.mkFloatingTuiLauncher {
        name = "volume-mixer";
        inherit config;
        exec = lib.getExe cfg.pkgs.ncpamixer;
        kittyExtraOpts = "-o window_padding_width=20";
        keybind = "$mod+p";
        title = "ncpamixer";
        width = 1200;
        height = 850;
      })
      { home.packages = [ cfg.pkgs.ncpamixer ]; }
    ]
  );
}
