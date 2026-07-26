{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.gui.feh;
in
{
  options.userSettings.gui.feh = {
    enable = lib.mkEnableOption "feh (visionneuse d'images)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    programs.feh = {
      enable = true;
      package = cfg.pkgs.feh;
    };

    stylix.targets.feh.enable = true;
  };
}
