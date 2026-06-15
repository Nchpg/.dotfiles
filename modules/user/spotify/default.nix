{ config, lib, inputs, ... }:

let
  cfg = config.userSettings.spotify;

  # Paquets spicetify (extensions / thèmes) pour la plateforme courante.
  spicePkgs = inputs.spicetify-nix.legacyPackages.${cfg.pkgs.stdenv.hostPlatform.system};

  # Couleurs Stylix (base16) -> color.ini spicetify. base16 renvoie déjà du hex
  # SANS '#', ce qui est exactement le format attendu par color.ini.
  c = config.lib.stylix.colors;
  stylixColorScheme = {
    text                = c.base05;
    subtext             = c.base04;
    sidebar-text        = c.base05;
    main                = c.base00;
    sidebar             = c.base01;
    player              = c.base01;
    card                = c.base01;
    shadow              = c.base00;
    selected-row        = c.base04;
    button              = c.base0D;
    button-active       = c.base0D;
    button-disabled     = c.base03;
    tab-bar             = c.base01;
    notification        = c.base0D;
    notification-error  = c.base08;
    misc                = c.base03;
  };
in
{
  options.userSettings.spotify = {
    enable = lib.mkEnableOption "Spotify patché via spicetify (sans pub)";

    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };

    theme = lib.mkOption {
      type = lib.types.str;
      default = "text";
      description = ''
        Thème spicetify à appliquer (cf. spicetify-nix `themes`, ex. "text",
        "default", "dribbblish", "catppuccin"). Mettre "" pour garder l'UI
        Spotify d'origine (extensions seules, aucun theming).
      '';
    };

    stylixColors = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Injecte les couleurs Stylix dans le thème (color.ini généré). Sans
        effet si `theme = ""`. Désactiver si le rendu casse après une MAJ.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.spicetify = {
      enable = true;
      spotifyPackage = cfg.pkgs.spotify;

      # Blocage des pubs. adblockify est le successeur le plus à jour ;
      # adblock (classique) est gardé en complément.
      enabledExtensions = with spicePkgs.extensions; [
        adblockify
        adblock
      ];
    }
    # Theming optionnel : seulement si un thème est demandé.
    // lib.optionalAttrs (cfg.theme != "") {
      theme = spicePkgs.themes.${cfg.theme};
      customColorScheme = lib.mkIf cfg.stylixColors stylixColorScheme;
    };
  };
}
