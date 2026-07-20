{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.agents.gemini;

  # Le paquet nixpkgs s'appelle antigravity-cli et fournit le binaire `agy`
  # (Google a renommé Gemini CLI en Antigravity) : wrapper pour garder la
  # commande `gemini`, alias historique conservé pour la mémoire musculaire
  # (cf. commit "fix: swap gemini-cli alias for antigravity-cli").
  gemini-wrapper = cfg.pkgs.writeShellScriptBin "gemini" ''
    exec ${cfg.pkgs.antigravity-cli}/bin/agy "$@"
  '';
in
{
  options.userSettings.agents.gemini = {
    enable = lib.mkEnableOption "Gemini (antigravity-cli)";
    # Défaut sur unstable, comme les autres agents IA de ce dossier.
    pkgs = import ../../../../lib/mk-pkgs-option.nix {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ gemini-wrapper ];
  };
}
