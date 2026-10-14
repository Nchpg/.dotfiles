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
      # Défaut true : tous les users sont thémés. Même sur un serveur, stylix
      # thémise neovim/tmux/bat, dont les couleurs sont écrites en dur dans leur
      # config — la palette ANSI, elle, vient du terminal client — et sans lui
      # le `colorscheme base16-stylix` du module vim n'existe pas (E185). Les
      # targets GTK/Qt/GNOME restent hors du store sans systemSettings.desktop.
      enable = lib.mkEnableOption "Enable stylix theming" // {
        default = true;
      };
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

  config = lib.mkMerge [
    {
      # Hors du mkIf, sinon un profil SANS stylix (server) laisse le module
      # upstream à son autoEnable = true : il active alors tous ses targets,
      # dont `overlays`, qui écrit dans nixpkgs.overlays — interdit sous
      # home-manager.useGlobalPkgs (warning de dépréciation, et bientôt une
      # assertion). On n'active jamais de target implicitement, ici comme
      # dans le module système.
      stylix.autoEnable = false;
    }

    (lib.mkIf cfg.enable {
      stylix = {
        enable = true;

        # Seuls targets réservés aux postes graphiques : sur un host headless
        # (profil server) ils ne thémiseraient rien mais tireraient GTK/Qt/
        # GNOME dans le store. Les targets qui comptent en SSH — vim, tmux,
        # bat — sont activés par leur propre module et restent actifs ici.
        targets = lib.optionalAttrs osConfig.systemSettings.desktop.enable {
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
    })
  ];
}
