{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.mistral;
in
{
  options.userSettings.agents.mistral = {
    enable = lib.mkEnableOption "Mistral Vibe CLI";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    # 6 tests Textual (UI) échouent dans le sandbox (timing).
    home.packages = [
      (cfg.pkgs.mistral-vibe.overrideAttrs (_old: {
        doInstallCheck = false;
      }))
    ];
  };
}
