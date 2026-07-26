{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.opencode;
in
{
  options.userSettings.agents.opencode = {
    enable = lib.mkEnableOption "OpenCode CLI";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.opencode ];
  };
}
