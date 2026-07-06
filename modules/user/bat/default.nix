{ config, lib, ... }:

let
  cfg = config.userSettings.bat;

  # En dark on garde le thème bat historique « gruvbox-dark » (rendu identique
  # à avant) ; en light on laisse Stylix appliquer base16-stylix (le mkForce
  # inconditionnel gardait bat sombre même en variante light).
  isDark = (config.userSettings.stylix.themeconfig.polarity or "dark") == "dark";
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
      config.theme = lib.mkIf isDark (lib.mkForce "gruvbox-dark");
    };

    home.packages = with cfg.pkgs; [
      bat-extras.batgrep
      bat-extras.batman
    ];
  };
}
