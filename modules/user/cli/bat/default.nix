{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.cli.bat;
in
{
  options = {
    userSettings.cli.bat = {
      # Défaut true : socle commun à tous les users (comme common.nix).
      enable = lib.mkEnableOption "bat (cat amélioré) + batgrep/batman" // {
        default = true;
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.bat = {
      enable = true;
      package = cfg.pkgs.bat;
      # Polarité déléguée à bat lui-même (≥ 0.25, détecte le fond du terminal) :
      # thèmes natifs gruvbox, pas de branchement dark/light côté Nix, reste
      # gruvbox quel que soit darkTheme/lightTheme. Nécessite de couper le
      # target stylix (ci-dessous), qui poserait sinon un `theme` prioritaire.
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
