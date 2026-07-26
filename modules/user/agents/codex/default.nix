{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.codex;
in
{
  options.userSettings.agents.codex = {
    enable = lib.mkEnableOption "Codex CLI";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.codex ];
  };
}
