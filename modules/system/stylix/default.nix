{
  lib,
  config,
  myLib,
  pkgs-stable,
  inputs,
  themes,
  ...
}:

let
  cfg = config.systemSettings.stylix;

  themesEnum = lib.types.enum themes.names;

  activeTheme = if cfg.variant == "light" then cfg.lightTheme else cfg.darkTheme;
in
{
  imports = [ inputs.stylix.nixosModules.stylix ];

  options = {
    systemSettings.stylix = {
      enable = lib.mkEnableOption "thème Stylix système (GDM, console)";

      variant = lib.mkOption {
        type = lib.types.enum [
          "dark"
          "light"
        ];
        default = "dark";
        description = ''
          Variante active, injectée par la cible du flake : ne pas la définir dans un profil.
        '';
      };

      darkTheme = lib.mkOption {
        type = themesEnum;
        default = "gruvbox-dark-custom";
        description = "Thème utilisé quand variant = \"dark\".";
      };

      wallpaper = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum themes.wallpaperNames);
        default = null;
        description = "Fond d'écran GDM (nom de themes/wallpapers.nix). null = celui du thème.";
      };

      lightTheme = lib.mkOption {
        type = themesEnum;
        default = "gruvbox-light-hard";
        description = "Thème utilisé quand variant = \"light\".";
      };

      theme = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Thème base16 actif (calculé depuis `variant`), lu par le module user.";
      };

      pkgs = myLib.mkPkgsOption {
        inherit lib config;
        default = pkgs-stable;
      };
    };
  };

  config = lib.mkMerge [
    {
      # Hors du mkIf : l'option est readOnly sans défaut, lue par le module user.
      systemSettings.stylix.theme = activeTheme;
    }

    (lib.mkIf cfg.enable {
      stylix = {
        enable = true;
        autoEnable = false;

        homeManagerIntegration.autoImport = false;

        # Recompile gnome-shell (~190 Mio de deps par variante) : inutile hors desktop.
        overlays.enable = config.systemSettings.desktop.enable;

        targets = {
          gnome.enable = config.systemSettings.desktop.enable;
          console.enable = true;
        };

        fonts = (themes.fontsFor cfg.pkgs).stylix;
      }
      // themes.stylixSettings {
        inherit (cfg) pkgs wallpaper;
        theme = activeTheme;
      };
    })
  ];
}
