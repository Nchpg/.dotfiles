{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.terminal.kitty;

  # Stylix code en dur `target = "base16"` pour kitty : même avec un scheme
  # base24, color9-14 restent mappés sur base08-0E ("rouge vif" = "rouge").
  # Rétabli plus bas. `? base12` (pas le repli mkBase24 de base16.nix) :
  # parseScheme n'invente pas les slots absents.
  scheme = themes.parseScheme config.userSettings.stylix.theme;
  isBase24 = config.userSettings.stylix.enable && scheme ? base12;
in
{
  options = {
    userSettings.terminal.kitty = {
      enable = lib.mkEnableOption "Enable kitty terminal";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      shell = myLib.mkTerminalShellOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {

        programs.kitty = {
          enable = true;
          package = cfg.pkgs.kitty;

          settings = {
            shell = myLib.mkTerminalShellBin { inherit (cfg) pkgs shell; };
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
          };
          extraConfig = ''
            enable_audio_bell no
            map ctrl+equal change_font_size all +2.0
            map ctrl+minus change_font_size all -2.0
            map ctrl+kp_add change_font_size all +2.0
            map ctrl+kp_subtract change_font_size all -2.0
            map ctrl+c copy_or_interrupt
            map ctrl+alt+c copy_to_clipboard
            map ctrl+shift+v paste_from_clipboard
            # Surtout PAS de `map ctrl+v` : des TUI comme Claude Code collent
            # une image en recevant Ctrl+V et en lisant eux-mêmes wl-paste ;
            # un bind kitty interceptant la touche pour un collage TEXTE
            # casserait ça silencieusement (rien ne se passe).
          '';
        };

        stylix.targets.kitty.enable = true;
      }

      # Bloc séparé : deux définitions du même attribut dans un attrset sont
      # une erreur d'éval. mkAfter : doit passer après l'include de stylix
      # (kitty applique la dernière valeur lue, pas besoin de couper le target).
      (lib.mkIf isBase24 {
        programs.kitty.extraConfig = lib.mkAfter ''

          # --- base24 (cf. modules/user/terminal/kitty) -------------------
          selection_background #${scheme.base05}
          selection_foreground #${scheme.base00}
          color9 #${scheme.base12}
          color10 #${scheme.base14}
          color11 #${scheme.base13}
          color12 #${scheme.base16}
          color13 #${scheme.base17}
          color14 #${scheme.base15}
        '';
      })
    ]
  );
}
