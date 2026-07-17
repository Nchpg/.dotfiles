{
  lib,
  config,
  osConfig,
  ...
}:

let
  cfg = config.userSettings.stylix;

  # API des thèmes (noms auto-découverts, bloc stylix commun) — partagée avec
  # modules/system/stylix, cf. modules/themes/default.nix.
  themes = import ../../themes lib;
in
{
  options = {
    userSettings.stylix = {
      enable = lib.mkEnableOption "Enable stylix theming";
      theme = lib.mkOption {
        # Par défaut, on suit le thème système (systemSettings.stylix.theme) :
        # ainsi basculer le thème système flippe aussi la session de l'user.
        # Un user peut toujours surcharger (cf. root / guest qui fixent le leur).
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
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
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

      # Polices partagées avec le module système (GDM) et installées par
      # modules/system/fonts — source unique : modules/themes/fonts.nix.
      fonts = (import ../../themes/fonts.nix cfg.pkgs).stylix;
    }
    # Scheme base16 + polarité + wallpaper du thème choisi (bloc commun avec
    # le module système, cf. modules/themes/default.nix).
    // themes.stylixSettings {
      inherit (cfg) pkgs theme wallpaper;
    };
  };
}
