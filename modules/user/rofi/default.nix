{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.rofi;
  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  fontSize = toString config.stylix.fonts.sizes.applications;
in
{
  options.userSettings.rofi = {
    enable = lib.mkEnableOption "lanceur rofi (remplace wofi + dmenu)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
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
      theme =
        let
          inherit (config.lib.formats.rasi) mkLiteral;
        in
        {
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

    # Icônes SVG maison, colorées avec la couleur de texte du thème (base05).
    # Adwaita ne fournit que des variantes -symbolic en #2e3436, invisibles sur
    # le fond foncé de rofi : on génère donc nos propres glyphes visibles.
    xdg.dataFile."icons/rofi-shutdown.svg".text = ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
        <path fill="none" stroke="${c.base05}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
              d="M12 3 v9 M7.05 7.05 a7 7 0 1 0 9.9 0"/>
      </svg>
    '';
    xdg.dataFile."icons/rofi-reboot.svg".text = ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
        <path fill="none" stroke="${c.base05}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
              d="M21 12 a9 9 0 1 1 -2.64 -6.36 M21 3 v5 h-5"/>
      </svg>
    '';

    # Entrée "Shutdown" visible dans rofi drun ($mod+d).
    # systemctl poweroff : pas besoin de sudo, autorisé par polkit pour la
    # session graphique active (contrairement à `shutdown now` qui exige root).
    xdg.dataFile."applications/shutdown.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Shutdown
      Comment=Éteindre la machine immédiatement
      Icon=${config.xdg.dataHome}/icons/rofi-shutdown.svg
      Exec=systemctl poweroff
      Terminal=false
    '';

    # Entrée "Reboot" visible dans rofi drun ($mod+d).
    xdg.dataFile."applications/reboot.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Reboot
      Comment=Redémarrer la machine immédiatement
      Icon=${config.xdg.dataHome}/icons/rofi-reboot.svg
      Exec=systemctl reboot
      Terminal=false
    '';

    # Fenêtre rofi flottante dans sway.
    home.file.".config/sway/conf.d/rofi.conf".text = ''
      for_window [app_id="rofi"] floating enable, border none
    '';
  };
}
