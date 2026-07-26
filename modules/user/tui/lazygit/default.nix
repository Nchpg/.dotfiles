{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.lazygit;
in
{
  options.userSettings.tui.lazygit = {
    enable = lib.mkEnableOption "lazygit (TUI git)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    programs.lazygit = {
      enable = true;
      package = cfg.pkgs.lazygit;
    };

    stylix.targets.lazygit.enable = true;
  };
}
