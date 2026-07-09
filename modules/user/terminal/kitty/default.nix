{ config, lib, ... }:

let
  cfg = config.userSettings.terminal.kitty;

  # Couleurs custom historiques (fond #262626, accents pastel), volontairement
  # différentes de la palette base16. Appliquées UNIQUEMENT en dark pour garder
  # ce rendu ; en light on n'écrase rien → Stylix (targets.kitty) pose toutes
  # les couleurs. Avant, ces valeurs en dur restaient aussi en variante light
  # (fond sombre après `theme light`).
  isDark = (config.userSettings.stylix.themeconfig.polarity or "dark") == "dark";
  darkColors = {
    ## The basic colors
    foreground = "#cdd6f4";
    background = "#262626";
    selection_foreground = "#1e1e2e";
    selection_background = "#f5e0dc";

    ## Cursor colors
    cursor = "#f5e0dc";
    cursor_text_color = "#1e1e2e";

    ## URL underline color when hovering with mouse
    url_color = "#f5e0dc";

    ## Kitty window border colors
    active_border_color = "#b4befe";
    inactive_border_color = "#6c7086";
    bell_border_color = "#f9e2af";

    ## Tab bar colors
    active_tab_foreground = "#11111b";
    active_tab_background = "#cba6f7";
    inactive_tab_foreground = "#cdd6f4";
    inactive_tab_background = "#181825";
    tab_bar_background = "#11111b";
  };
in
{
  options = {
    userSettings.terminal.kitty = {
      enable = lib.mkEnableOption "Enable kitty terminal";
      pkgs = lib.mkOption {
        type = lib.types.pkgs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
      shell = lib.mkOption {
        type = lib.types.str;
        default = config.userSettings.shell.default;
        description = "Shell to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {

    programs.kitty = {
      enable = true;
      package = cfg.pkgs.kitty;

      settings = {
        shell = "${cfg.pkgs."${cfg.shell}"}/bin/${cfg.shell}";
        confirm_os_window_close = 0;
        window_padding_width = 4;
        term = "xterm-256color";

        # Tabs
        tab_bar_min_tabs = 2;
        tab_bar_edge = "bottom";
        tab_bar_style = "powerline";
        tab_powerline_style = "round";
        tab_title_template = "{title}{' :{}:'.format(num_windows) if num_windows > 1 else ''}";

        ## Animate cursor
        cursor_trail = 3;
        cursor_trail_decay = "0.1 0.4";
        cursor_shape = "block";

        ## OS Window titlebar colors
        wayland_titlebar_color = "system";
        macos_titlebar_color = "system";
      }
      # Couleurs custom en dark uniquement (cf. darkColors dans le let).
      // lib.optionalAttrs isDark darkColors;

      extraConfig = ''
        enable_audio_bell no
        map ctrl+equal change_font_size all +2.0
        map ctrl+minus change_font_size all -2.0
        map ctrl+kp_add change_font_size all +2.0
        map ctrl+kp_subtract change_font_size all -2.0
        map ctrl+c copy_or_interrupt
        map ctrl+alt+c copy_to_clipboard
        map ctrl+shift+v paste_from_clipboard
        # Surtout PAS de `map ctrl+v paste_from_clipboard` : kitty
        # intercepterait la touche pour faire un collage TEXTE, et les TUI
        # comme Claude Code ne la recevraient jamais — or leur collage
        # d'image fonctionne en recevant Ctrl+V puis en lisant eux-mêmes le
        # presse-papier (wl-paste). Presse-papier avec image + bind kitty =
        # rien ne se passe. Sans bind, Ctrl+V est transmis à l'application ;
        # le collage texte reste sur Ctrl+Shift+V.
      '';
    };

    stylix.targets.kitty.enable = true;
  };
}
