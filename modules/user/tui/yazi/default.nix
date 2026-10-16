{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.yazi;
in
{
  options = {
    userSettings.tui.yazi = {
      enable = lib.mkEnableOption "Enable yazi";

      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.yazi = {
      enable = true;
      package = cfg.pkgs.yazi;
      # 26.05 a changé le défaut du wrapper "yy" → "y" ; on garde "yy".
      shellWrapperName = "yy";
    };

    # Pas de flavor manuel : écrirait le même theme.toml -> conflit avec Stylix.
    stylix.targets.yazi.enable = true;
  };
}
