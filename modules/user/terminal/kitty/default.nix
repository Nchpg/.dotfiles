{
  config,
  lib,
  myLib,
  themes,
  ...
}:

let
  cfg = config.userSettings.terminal.kitty;

  # Stylix force target base16 : color9-14 restent mappés sur base08-0E en base24 (rétabli plus bas).
  scheme = themes.parseScheme config.userSettings.stylix.theme;
  isBase24 = config.userSettings.stylix.enable && scheme ? base12;
in
{
  options = {
    userSettings.terminal.kitty = {
      enable = lib.mkEnableOption "Enable kitty terminal";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
      shell = myLib.desktop.mkTerminalShellOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        programs.kitty = {
          enable = true;
          package = cfg.pkgs.kitty;

          settings = {
            shell = myLib.desktop.mkTerminalShellBin { inherit (cfg) pkgs shell; };
            confirm_os_window_close = 0;
            window_padding_width = 4;
            term = "xterm-256color";

            tab_bar_min_tabs = 2;
            tab_bar_edge = "bottom";
            tab_bar_style = "powerline";
            tab_powerline_style = "round";
            tab_title_template = "{title}{' :{}:'.format(num_windows) if num_windows > 1 else ''}";

            cursor_trail = 3;
            cursor_trail_decay = "0.1 0.4";
            cursor_shape = "block";

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
            # Pas de `map ctrl+v` : les TUI (Claude Code) collent les images eux-mêmes.

            # AZERTY : alt+& … alt+ç envoient alt+1 … alt+9 (tabs herdr sans shift).
            map alt+& send_key alt+1
            map alt+é send_key alt+2
            map alt+" send_key alt+3
            map alt+' send_key alt+4
            map alt+( send_key alt+5
            map alt+- send_key alt+6
            map alt+è send_key alt+7
            map alt+_ send_key alt+8
            map alt+ç send_key alt+9
          '';
        };

        stylix.targets.kitty.enable = true;
      }

      # mkAfter : après l'include de stylix (kitty garde la dernière valeur lue).
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
