{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.mpv;
in
{
  options.userSettings.gui.mpv = {
    enable = lib.mkEnableOption "mpv (lecteur média)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.mpv ];
  };
}
