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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
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

        # $menu : lanceur d'applis, sur $mod+d et la touche Recherche.
        home.file.".config/sway/conf.d/rofi.conf".text = ''
          set $menu rofi -show drun
          bindsym $mod+d exec $menu
          bindsym XF86Search exec $menu

          for_window [app_id="rofi"] floating enable, border none
        '';
      }

      # Actions système dans le lanceur (glyphes maison, cf. lib/desktop/rofi-action.nix).
      # systemctl poweroff : pas besoin de sudo (polkit, session graphique
      # active), contrairement à `shutdown now`. L'entrée `awake` vient du
      # module lock.
      (myLib.desktop.mkRofiAction {
        inherit config;
        name = "shutdown";
        label = "Shutdown";
        comment = "Éteindre la machine immédiatement";
        exec = "systemctl poweroff";
        color = c.base05;
        path = "M12 3 v9 M7.05 7.05 a7 7 0 1 0 9.9 0";
      })
      (myLib.desktop.mkRofiAction {
        inherit config;
        name = "reboot";
        label = "Reboot";
        comment = "Redémarrer la machine immédiatement";
        exec = "systemctl reboot";
        color = c.base05;
        path = "M21 12 a9 9 0 1 1 -2.64 -6.36 M21 3 v5 h-5";
      })
    ]
  );
}
