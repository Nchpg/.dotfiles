{
  lib,
  config,
  osConfig,
  inputs,
  ...
}:

let
  cfg = config.userSettings.stylix;

  # Partagée avec modules/system/stylix, cf. modules/themes/default.nix.
  themes = import ../../themes lib inputs;
in
{
  options = {
    userSettings.stylix = {
      enable = lib.mkEnableOption "Enable stylix theming";
      theme = lib.mkOption {
        # Suit le thème système par défaut : basculer le système flippe aussi
        # la session (root/guest surchargent le leur).
        default = osConfig.systemSettings.stylix.theme;
        type = lib.types.enum themes.names;
        description = "Theme for stylix to use system wide. A list of themes can be found in the `modules/themes/schemes` directory.";
      };
      wallpaper = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum themes.wallpaperNames);
        default = null;
        description = ''
          Fond d'écran de session à la place de celui du thème — un nom de
          modules/themes/wallpapers.nix. null = le fond par défaut du thème.
        '';
      };
      pkgs = import ../../../lib/mk-pkgs-option.nix { inherit lib config; };
    };
  };

  config = lib.mkIf cfg.enable {
    stylix = {
      enable = true;
      autoEnable = false;
      targets = {
        gtk.enable = true;
        qt.enable = true;
        gnome.enable = true;
      };

      # Source unique : modules/themes/fonts.nix.
      fonts = (import ../../themes/fonts.nix cfg.pkgs).stylix;
    }
    // themes.stylixSettings {
      inherit (cfg) pkgs theme wallpaper;
    };
  };
}
