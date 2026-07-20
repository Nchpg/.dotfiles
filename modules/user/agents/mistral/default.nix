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
    # Paquet nixpkgs mistral-vibe, binaire réel `vibe` (+ `vibe-acp`) — pas de
    # renommage forcé en `mistral`, aucun alias historique à préserver ici
    # contrairement à gemini.
    enable = lib.mkEnableOption "Mistral Vibe CLI";
    # Défaut sur unstable, comme les autres agents IA de ce dossier.
    pkgs = import ../../../../lib/mk-pkgs-option.nix {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    # doInstallCheck (pas doCheck, déjà à false par défaut ici) fait tourner
    # la suite de tests Textual du paquet à l'installCheckPhase : 6 tests
    # d'UI (message queue, onboarding) échouent dans ce sandbox de build,
    # indépendamment de notre config (timing-sensitive, pas dans la liste
    # disabledTests déjà maintenue par nixpkgs pour ce paquet). Binaire
    # vérifié fonctionnel malgré tout (`vibe --version`/`--help`).
    home.packages = [
      (cfg.pkgs.mistral-vibe.overrideAttrs (_old: {
        doInstallCheck = false;
      }))
    ];
  };
}
