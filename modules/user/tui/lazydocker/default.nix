{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.lazydocker;
in
{
  options.userSettings.tui.lazydocker = {
    enable = lib.mkEnableOption "lazydocker (TUI Docker)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.lazydocker ];
  };
}
