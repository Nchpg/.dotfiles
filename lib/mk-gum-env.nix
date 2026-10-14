# Bloc bash partagé par tout ce qui pose des questions avec gum (`update`,
# `rebuild` pour `-u`, `genclean`, `dots`, et les TUI comme lg-control) :
# même palette partout, jamais le rose par défaut de gum.
#
# Deux jeux de variables, pour deux publics :
#   - GUM_* : lues par gum lui-même, quel que soit l'appelant ;
#   - UPDATE_COLOR_* : lues par scripts/lib/ui.sh, qui en tire aussi les
#     couleurs du texte des scripts du dépôt (récapitulatif d'`update`…).
#
# `colors` : une palette base16 au format de `config.lib.stylix.colors` (hex
# sans '#'), ou null. Sans palette (serveur sans Stylix), les rôles prennent
# les numéros de couleur du TERMINAL (4 = bleu, 2 = vert…) — que Stylix colore
# justement avec la même palette quand il est actif. UPDATE_COLOR_* n'est
# alors pas exporté : ui.sh retombe de lui-même sur ces mêmes numéros.
#
# `gum` : paquet à mettre en tête du PATH, ou null si l'appelant le fournit
# déjà (runtimeInputs d'un writeShellApplication).
{
  colors,
  gum ? null,
}:
let
  palette =
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
      };
in
(
  if gum != null then
    ''
      export PATH="${gum}/bin:$PATH"
    ''
  else
    ""
)
+ (
  if colors != null then
    with palette;
    ''
      export UPDATE_COLOR_ACCENT="${accent}" UPDATE_COLOR_OK="${ok}" UPDATE_COLOR_WARN="${warn}"
      export UPDATE_COLOR_ERR="${err}" UPDATE_COLOR_DIM="${dim}" UPDATE_COLOR_TEXT="${text}"
      export UPDATE_COLOR_BASE="${base}"
    ''
  else
    ""
)
+ (with palette; ''
  export GUM_CHOOSE_CURSOR_FOREGROUND="${accent}" GUM_CHOOSE_HEADER_FOREGROUND="${accent}"
  export GUM_CHOOSE_SELECTED_FOREGROUND="${ok}" GUM_CHOOSE_ITEM_FOREGROUND="${text}"
  export GUM_INPUT_PROMPT_FOREGROUND="${accent}" GUM_INPUT_HEADER_FOREGROUND="${accent}"
  export GUM_INPUT_CURSOR_FOREGROUND="${accent}" GUM_INPUT_PLACEHOLDER_FOREGROUND="${dim}"
  export GUM_CONFIRM_PROMPT_FOREGROUND="${accent}"
  export GUM_CONFIRM_SELECTED_BACKGROUND="${accent}" GUM_CONFIRM_SELECTED_FOREGROUND="${base}"
  export GUM_CONFIRM_UNSELECTED_BACKGROUND="${dim}" GUM_CONFIRM_UNSELECTED_FOREGROUND="${text}"
  export GUM_SPIN_SPINNER_FOREGROUND="${accent}"
'')
