{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.vlc;
in
{
  options.userSettings.gui.vlc = {
    enable = lib.mkEnableOption "VLC (lecteur vidéo)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.vlc ];
  };
}
