{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.cli.bat;
in
{
  options = {
    userSettings.cli.bat = {
      enable = lib.mkEnableOption "bat (cat amélioré) + batgrep/batman" // {
        default = true;
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.bat = {
      enable = true;
      package = cfg.pkgs.bat;
      # Le target stylix est coupé plus bas : il poserait un `theme` prioritaire.
      config = {
        theme-dark = "gruvbox-dark";
        theme-light = "gruvbox-light";
      };
    };

    stylix.targets.bat.enable = false;

    home.packages = with cfg.pkgs; [
      bat-extras.batgrep
      bat-extras.batman
    ];
  };
}
