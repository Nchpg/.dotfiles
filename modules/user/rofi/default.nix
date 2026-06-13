{ config, lib, pkgs-unstable, ... }:

let
  cfg = config.userSettings.rofi;
  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  fontSize = toString (config.stylix.fonts.sizes.applications);
in {
  options.userSettings.rofi = {
    enable = lib.mkEnableOption "lanceur rofi (remplace wofi + dmenu)";
    pkgs = lib.mkOption {
      type = lib.types.attrs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    # rofi-wayland : fork Wayland-natif de rofi.
    # Disponible dans unstable, pas encore dans stable 26.05.
    programs.rofi = {
      enable = true;
      package = pkgs-unstable.rofi;
      terminal = config.userSettings.terminal.default;
      extraConfig = {
        modi = "drun,run";
        show-icons = true;
        icon-theme = "Adwaita";
        drun-display-format = "{name}";
        disable-history = false;
        hide-scrollbar = true;
        display-drun = "  Apps";
        display-run = "  Run";
        sidebar-mode = false;
      };
      theme = let
        inherit (config.lib.formats.rasi) mkLiteral;
      in {
        "*" = {
          bg = mkLiteral c.base00;
          bg-alt = mkLiteral c.base01;
          fg = mkLiteral c.base05;
          fg-alt = mkLiteral c.base04;
          accent = mkLiteral c.base0D;
          urgent = mkLiteral c.base08;
          font-name = "${font} ${fontSize}";
          background-color = mkLiteral "transparent";
          text-color = mkLiteral "@fg";
        };

        "window" = {
          background-color = mkLiteral "@bg";
          border = mkLiteral "2px";
          border-color = mkLiteral "@accent";
          border-radius = mkLiteral "12px";
          padding = mkLiteral "16px";
          width = mkLiteral "680px";
        };

        "mainbox" = {
          background-color = mkLiteral "transparent";
          spacing = mkLiteral "8px";
        };

        "inputbar" = {
          background-color = mkLiteral "@bg-alt";
          border-radius = mkLiteral "8px";
          padding = mkLiteral "8px 12px";
          spacing = mkLiteral "8px";
          children = mkLiteral "[prompt, entry]";
        };

        "prompt" = {
          text-color = mkLiteral "@accent";
          font = mkLiteral "@font-name";
        };

        "entry" = {
          text-color = mkLiteral "@fg";
          font = mkLiteral "@font-name";
          placeholder = "Rechercher...";
          placeholder-color = mkLiteral "@fg-alt";
        };

        "listview" = {
          background-color = mkLiteral "transparent";
          lines = mkLiteral "14";
          spacing = mkLiteral "4px";
          scrollbar = mkLiteral "false";
        };

        "element" = {
          background-color = mkLiteral "transparent";
          border-radius = mkLiteral "8px";
          padding = mkLiteral "8px 12px";
          spacing = mkLiteral "8px";
        };

        "element selected" = {
          background-color = mkLiteral "@accent";
          text-color = mkLiteral "@bg";
        };

        "element-icon" = {
          size = mkLiteral "24px";
          vertical-align = mkLiteral "0.5";
        };

        "element-text" = {
          text-color = mkLiteral "inherit";
          vertical-align = mkLiteral "0.5";
          font = mkLiteral "@font-name";
        };

        "message" = {
          background-color = mkLiteral "@bg-alt";
          border-radius = mkLiteral "8px";
          padding = mkLiteral "8px 12px";
        };
      };
    };

    # Fenêtre rofi flottante dans sway.
    home.file.".config/sway/conf.d/rofi.conf".text = ''
      for_window [app_id="rofi"] floating enable, border none
    '';
  };
}
