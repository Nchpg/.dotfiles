{
  lib,
  config,
  osConfig,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.stylix;

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
        description = "Theme for stylix to use system wide. A list of themes can be found in the `themes/schemes` directory.";
      };
      wallpaper = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum themes.wallpaperNames);
        default = null;
        description = ''
          Fond d'écran de session à la place de celui du thème — un nom de
          themes/wallpapers.nix. null = le fond par défaut du thème.
        '';
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
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

      # Source unique : themes/fonts.nix.
      fonts = (themes.fontsFor cfg.pkgs).stylix;
    }
    // themes.stylixSettings {
      inherit (cfg) pkgs theme wallpaper;
    };
  };
}
