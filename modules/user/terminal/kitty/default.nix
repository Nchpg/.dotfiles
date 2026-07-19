{
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.userSettings.terminal.kitty;

  # Stylix code en dur `target = "base16"` pour kitty (son
  # modules/kitty/hm.nix) : même avec un scheme base24, color9-14 restent
  # mappés sur base08-0E, donc « rouge vif » = « rouge ». Cf. plus bas pour
  # le rétablissement.
  #
  # `? base12` et non le repli mkBase24 de base16.nix : parseScheme n'invente
  # pas les slots absents, donc un thème base16 n'active rien ici.
  themes = import ../../../themes lib inputs;
  scheme = themes.parseScheme config.userSettings.stylix.theme;
  isBase24 = config.userSettings.stylix.enable && scheme ? base12;
in
{
  options = {
    userSettings.terminal.kitty = {
      enable = lib.mkEnableOption "Enable kitty terminal";
      pkgs = import ../../../../lib/mk-pkgs-option.nix { inherit lib config; };
      shell = import ../../../../lib/mk-terminal-shell-option.nix { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {

        programs.kitty = {
          enable = true;
          package = cfg.pkgs.kitty;

          settings = {
            shell = import ../../../../lib/mk-terminal-shell-bin.nix { inherit (cfg) pkgs shell; };
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
          # Toutes les couleurs viennent de stylix (targets.kitty, activé plus
          # bas) : kitty suit le thème choisi dans les DEUX polarités. L'ancien
          # jeu de couleurs custom appliqué en dark (fond #262626, accents
          # pastel) vivait dans le scheme modules/themes/schemes/custom.nix,
          # supprimé depuis (cf. gruvbox-dark-custom pour un rendu proche) —
          # pour retrouver ce rendu partout : darkTheme = "gruvbox-dark-custom"
          # dans le profil.

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
      }

      # Bloc séparé car `extraConfig` est déjà défini plus haut : deux
      # définitions du même attribut dans un attrset sont une erreur d'éval.
      #
      # mkAfter : doit passer APRÈS l'`include` de stylix, sinon celui-ci
      # l'écraserait — kitty applique la dernière valeur lue, donc pas besoin
      # de désactiver son target. Reprend tinted-kitty/base24.mustache : les 6
      # couleurs vives, plus la sélection que ce template inverse.
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
