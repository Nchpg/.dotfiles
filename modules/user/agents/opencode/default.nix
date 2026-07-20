{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.agents.opencode;
in
{
  options.userSettings.agents.opencode = {
    enable = lib.mkEnableOption "OpenCode CLI";
    pkgs = import ../../../../lib/mk-pkgs-option.nix {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.opencode ];
  };
}
