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
      # Actif partout : le `colorscheme base16-stylix` de vim en dépend (E185).
      enable = lib.mkEnableOption "Enable stylix theming" // {
        default = true;
      };
      theme = lib.mkOption {
        default = osConfig.systemSettings.stylix.theme;
        type = lib.types.enum themes.names;
        description = "Theme for stylix to use system wide. A list of themes can be found in the `themes/schemes` directory.";
      };
      wallpaper = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum themes.wallpaperNames);
        default = null;
        description = "Fond d'écran de session (nom de themes/wallpapers.nix) ; null = celui du thème.";
      };
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };

  config = lib.mkMerge [
    {
      # Hors du mkIf : sinon autoEnable activerait le target `overlays`, interdit avec useGlobalPkgs.
      stylix.autoEnable = false;
    }

    (lib.mkIf cfg.enable {
      stylix = {
        enable = true;

        targets = lib.optionalAttrs osConfig.systemSettings.desktop.enable {
          gtk.enable = true;
          qt.enable = true;
          gnome.enable = true;
        };

        fonts = (themes.fontsFor cfg.pkgs).stylix;
      }
      // themes.stylixSettings {
        inherit (cfg) pkgs theme wallpaper;
      };
    })
  ];
}
