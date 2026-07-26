{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.broot;
in
{
  options.userSettings.tui.broot = {
    enable = lib.mkEnableOption "broot (navigateur d'arborescence)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.broot ];
  };
}
