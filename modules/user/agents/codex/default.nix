{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.agents.codex;
in
{
  options.userSettings.agents.codex = {
    enable = lib.mkEnableOption "Codex CLI";
    # Défaut sur unstable, comme les autres agents IA de ce dossier.
    pkgs = import ../../../../lib/mk-pkgs-option.nix {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.codex ];
  };
}
