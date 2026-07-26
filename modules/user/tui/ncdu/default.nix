{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.ncdu;
in
{
  options.userSettings.tui.ncdu = {
    enable = lib.mkEnableOption "ncdu (analyseur d'occupation disque)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.ncdu ];
  };
}
