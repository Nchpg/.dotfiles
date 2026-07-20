{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.agents.mistral;
in
{
  options.userSettings.agents.mistral = {
    # Paquet nixpkgs mistral-vibe, binaire réel `vibe` (+ `vibe-acp`).
    enable = lib.mkEnableOption "Mistral Vibe CLI";
    pkgs = import ../../../../lib/mk-pkgs-option.nix {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    # 6 tests Textual (UI) échouent à l'installCheckPhase dans ce sandbox,
    # timing-sensitive, indépendants de notre config. Binaire vérifié
    # fonctionnel malgré tout.
    home.packages = [
      (cfg.pkgs.mistral-vibe.overrideAttrs (_old: {
        doInstallCheck = false;
      }))
    ];
  };
}
