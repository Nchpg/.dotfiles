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

  # SOURCE DE VÉRITÉ lue par GDM/console ici, et par nchpg (modules/user/stylix).
  activeTheme = if cfg.variant == "light" then cfg.lightTheme else cfg.darkTheme;
in
{
  # Module Stylix NIVEAU SYSTÈME : thémise ce que le home-manager ne peut pas
  # atteindre (GDM via le target `gnome`, console/TTY). `variant` est injecté
  # par la CIBLE du flake (personal-gram = dark, -light = light) : `theme
  # dark|light|toggle` rebuilde l'autre cible sans modifier aucun fichier.
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
          Variante active. Ne PAS la définir dans un profil : elle est
          injectée par la cible du flake (personal-gram-light → "light").
          Bascule via la commande `theme dark|light|toggle`.
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
        description = ''
          Fond d'écran (GDM) à la place de celui du thème actif — un nom de
          themes/wallpapers.nix. null = le fond par défaut du thème.
        '';
      };

      lightTheme = lib.mkOption {
        type = themesEnum;
        default = "gruvbox-light-hard";
        description = "Thème utilisé quand variant = \"light\".";
      };

      theme = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = ''
          Thème base16 effectivement actif (calculé depuis `variant`). Lu par
          le module user pour que nchpg suive le thème système. Lecture seule.
        '';
      };

      pkgs = myLib.mkPkgsOption {
        inherit lib config;
        default = pkgs-stable;
      };
    };
  };

  config = lib.mkMerge [
    {
      # Hors du mkIf : le calcul ne dépend pas de `enable`, et l'option étant
      # readOnly sans default, un profil sans stylix système casserait
      # l'éval du module user sinon.
      systemSettings.stylix.theme = activeTheme;
    }

    (lib.mkIf cfg.enable {
      # La commande `theme` (scripts/theme.sh) n'est installée qu'avec Stylix,
      # cf. modules/system/commands.
      stylix = {
        enable = true;
        autoEnable = false; # on n'active que ce qu'on veut

        # Module home-manager géré à part (profiles/default.nix, suivi via
        # userSettings.stylix.theme) : sans ce false, l'auto-import forcerait
        # son scheme dans CHAQUE user en read-only (followSystem).
        homeManagerIntegration.autoImport = false;

        # Réactivé malgré autoEnable = false : seule façon de thémiser GDM
        # (pas d'extensions sur l'écran de login) est de remplacer
        # gnome-shell-theme.gresource via l'overlay nixpkgs de stylix. Sans
        # ça, GDM reste en Adwaita sombre.
        # COÛT : gnome-shell recompilé depuis les sources (+session,
        # browser-connector, ~190 Mio de deps de build). dark/light produisent
        # deux gnome-shell différents : la première bascule après un
        # `rebuild -u` ou un changement de thème repaye la compilation.
        # D'où le suivi de desktop.enable : sur un host headless, cet overlay
        # ne thémiserait aucun écran de login et ferait payer la compilation
        # pour rien.
        overlays.enable = config.systemSettings.desktop.enable;

        targets = {
          gnome.enable = config.systemSettings.desktop.enable; # ⇒ thémise GDM (login screen)
          # Jamais conditionnée : sur un host headless, les TTY sont le seul
          # rendu local, donc le seul endroit où le thème se voit encore.
          console.enable = true; # ⇒ thémise les TTY
        };

        # Source unique : themes/fonts.nix.
        fonts = (themes.fontsFor cfg.pkgs).stylix;
      }
      // themes.stylixSettings {
        inherit (cfg) pkgs wallpaper;
        theme = activeTheme;
      };
    })
  ];
}
