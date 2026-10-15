# Bloc bash qui donne aux menus gum la palette du thème (cf. ui-palette.nix),
# pour les TUI qui en affichent (lg-control, bt-combine) : jamais le rose par
# défaut de gum. Les commandes du dépôt, elles, tirent les mêmes rôles de
# scripts/lib/ui.sh.
#
# `colors` : palette base16 au format de `config.lib.stylix.colors`, ou null.
{ colors }:
with import ./ui-palette.nix colors;
''
  export GUM_CHOOSE_CURSOR_FOREGROUND="${accent}" GUM_CHOOSE_HEADER_FOREGROUND="${accent}"
  export GUM_CHOOSE_SELECTED_FOREGROUND="${ok}" GUM_CHOOSE_ITEM_FOREGROUND="${text}"
  export GUM_INPUT_PROMPT_FOREGROUND="${accent}" GUM_INPUT_HEADER_FOREGROUND="${accent}"
  export GUM_INPUT_CURSOR_FOREGROUND="${accent}" GUM_INPUT_PLACEHOLDER_FOREGROUND="${dim}"
  export GUM_CONFIRM_PROMPT_FOREGROUND="${accent}"
  export GUM_CONFIRM_SELECTED_BACKGROUND="${accent}" GUM_CONFIRM_SELECTED_FOREGROUND="${base}"
  export GUM_CONFIRM_UNSELECTED_BACKGROUND="${dim}" GUM_CONFIRM_UNSELECTED_FOREGROUND="${text}"
  export GUM_SPIN_SPINNER_FOREGROUND="${accent}"
''
