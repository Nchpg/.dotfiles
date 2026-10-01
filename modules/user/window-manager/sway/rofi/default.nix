{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.windowManager.sway.rofi;
  c = config.lib.stylix.colors.withHashtag;
  font = config.stylix.fonts.sansSerif.name;
  fontSize = toString config.stylix.fonts.sizes.applications;
in
{
  options.userSettings.windowManager.sway.rofi = {
    # Suit sway : sert le lanceur $mod+d et $mod+v de cliphist.
    enable = lib.mkEnableOption "lanceur rofi (remplace wofi + dmenu)" // {
      default = config.userSettings.windowManager.sway.enable;
    };

    # rofi-wayland pas encore dans stable 26.05.
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    programs.rofi = {
      enable = true;
      package = cfg.pkgs.rofi;
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

    # Adwaita ne fournit que des -symbolic en #2e3436, invisibles sur le fond
    # foncé de rofi : glyphes maison colorés avec base05.
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

    # systemctl poweroff : pas besoin de sudo (polkit, session graphique
    # active), contrairement à `shutdown now`.
    xdg.dataFile."applications/shutdown.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Shutdown
      Comment=Éteindre la machine immédiatement
      Icon=${config.xdg.dataHome}/icons/rofi-shutdown.svg
      Exec=systemctl poweroff
      Terminal=false
    '';

    xdg.dataFile."applications/reboot.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Reboot
      Comment=Redémarrer la machine immédiatement
      Icon=${config.xdg.dataHome}/icons/rofi-reboot.svg
      Exec=systemctl reboot
      Terminal=false
    '';

    # `awake` (cf. ../default.nix) : verrouille en gardant la machine éveillée
    # capot fermé. Tasse en orange (base09), la couleur de l'anneau de ce
    # verrou-là, pour l'associer d'un coup d'œil.
    xdg.dataFile."icons/rofi-awake.svg".text = ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
        <path fill="none" stroke="${c.base09}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
              d="M4 10 h12 v4 a5 5 0 0 1 -5 5 h-2 a5 5 0 0 1 -5 -5 z M16 11 h1.5 a2.5 2.5 0 0 1 0 5 H16 M8 3 v4 M12 3 v4"/>
      </svg>
    '';

    xdg.dataFile."applications/awake.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Awake
      Comment=Verrouiller en restant éveillé capot fermé
      Icon=${config.xdg.dataHome}/icons/rofi-awake.svg
      Exec=awake
      Terminal=false
    '';

    home.file.".config/sway/conf.d/rofi.conf".text = ''
      for_window [app_id="rofi"] floating enable, border none
    '';
  };
}
