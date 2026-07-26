{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.terminal.foot;
in
{
  options = {
    userSettings.terminal.foot = {
      enable = lib.mkEnableOption "Enable foot terminal";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      shell = myLib.mkTerminalShellOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.foot = {
      enable = true;
      package = cfg.pkgs.foot;

      settings = {
        main = {
          shell = myLib.mkTerminalShellBin { inherit (cfg) pkgs shell; };
        };
      };
    };

    stylix.targets.foot.enable = true;
  };
}
