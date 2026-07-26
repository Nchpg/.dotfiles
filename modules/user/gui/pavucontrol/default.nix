{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.pavucontrol;
in
{
  options.userSettings.gui.pavucontrol = {
    enable = lib.mkEnableOption "pavucontrol (mixeur audio GUI)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.pavucontrol ];
  };
}
