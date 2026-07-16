{ config, lib, ... }:

let
  cfg = config.userSettings.bat;
in
{
  options = {
    userSettings.bat = {
      # Défaut true : bat fait partie du socle commun à tous les users (root et
      # guest inclus), comme les utilitaires de modules/user/common.nix.
      enable = lib.mkEnableOption "bat (cat amélioré) + batgrep/batman" // {
        default = true;
      };
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.bat = {
      enable = true;
      package = cfg.pkgs.bat;
      # Polarité déléguée à bat lui-même (≥ 0.25) : il détecte le fond du
      # terminal à chaque invocation et choisit le bon thème — thèmes NATIFS
      # bat (rendu riche, cf. gruvbox-dark historique), aucun branchement
      # dark/light côté Nix. Choix de style assumé : bat reste gruvbox quel
      # que soit darkTheme/lightTheme. Dans un TTY/ssh sans détection, bat
      # retombe sur theme-dark (bénin). Nécessite de couper le target stylix
      # (ci-dessous), qui poserait sinon un `theme` prioritaire sur la paire
      # theme-dark/theme-light.
      config = {
        theme-dark = "gruvbox-dark";
        theme-light = "gruvbox-light";
      };
    };

    stylix.targets.bat.enable = false;

    home.packages = with cfg.pkgs; [
      bat-extras.batgrep
      bat-extras.batman
    ];
  };
}
