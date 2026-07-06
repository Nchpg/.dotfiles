{ config, lib, ... }:

let
  cfg = config.userSettings.posting;
  c = config.lib.stylix.colors.withHashtag;
in {
  options.userSettings.posting = {
    enable = lib.mkEnableOption "Enable posting (TUI HTTP client)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.pkgs.posting ];

    # Configuration de posting : on lui dit d'utiliser notre thème stylix.
    xdg.configFile."posting/config.yaml".text = ''
      theme: stylix
      watch_themes: false
    '';

    # Thème Stylix pour posting (basé sur Textual).
    # On mappe la palette base16 de Stylix sur les variables de posting.
    # On le place dans xdg.dataFile car posting cherche dans ~/.local/share/posting/themes
    xdg.dataFile."posting/themes/stylix.yaml".text = ''
      name: stylix
      primary: "${c.base0D}"
      secondary: "${c.base0B}"
      accent: "${c.base0D}"
      background: "${c.base00}"
      surface: "${c.base01}"
      panel: "${c.base01}"
      foreground: "${c.base05}"
      error: "${c.base08}"
      success: "${c.base0B}"
      warning: "${c.base0A}"
    '';
  };
}
