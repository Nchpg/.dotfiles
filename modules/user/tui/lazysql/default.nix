{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.lazysql;
in
{
  options.userSettings.tui.lazysql = {
    enable = lib.mkEnableOption "lazysql (TUI client SQL)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.lazysql ];
  };
}
