# Palette des interfaces du dépôt, PAR RÔLES : une palette base16 au format de
# `config.lib.stylix.colors` (hex sans '#') -> { accent, ok, warn, err, dim,
# text, base } en « #rrggbb ». Sans palette (null : serveur sans Stylix), les
# numéros de couleur du TERMINAL (4 = bleu, 2 = vert…), que Stylix colore
# justement avec la même palette quand il est actif.
#
# Lue par le paquet des commandes (DOTS_COLOR_*, cf. scripts/default.nix et
# scripts/lib/ui.sh) et par mkGumEnv (menus gum des TUI).
colors:
if colors != null then
  {
    accent = "#${colors.base0D}";
    ok = "#${colors.base0B}";
    warn = "#${colors.base0A}";
    err = "#${colors.base08}";
    dim = "#${colors.base03}";
    text = "#${colors.base05}";
    base = "#${colors.base00}";
  }
else
  {
    accent = "4";
    ok = "2";
    warn = "3";
    err = "1";
    dim = "8";
    text = "7";
    base = "0";
  }
