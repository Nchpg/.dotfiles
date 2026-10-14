# Bloc bash partagé par les commandes à menus gum (`update`, `rebuild` pour
# `-u`, `genclean`) : met gum dans le PATH et passe la palette Stylix
# (UPDATE_COLOR_*), pour le même rendu partout. Sans Stylix (serveur), les
# scripts gardent leurs couleurs par défaut.
{
  lib,
  config,
  gum,
}:
let
  c = config.lib.stylix.colors;
in
''
  export PATH="${gum}/bin:$PATH"
''
+ lib.optionalString config.stylix.enable ''
  export UPDATE_COLOR_ACCENT="#${c.base0D}"
  export UPDATE_COLOR_OK="#${c.base0B}"
  export UPDATE_COLOR_WARN="#${c.base0A}"
  export UPDATE_COLOR_ERR="#${c.base08}"
  export UPDATE_COLOR_DIM="#${c.base03}"
  export UPDATE_COLOR_TEXT="#${c.base05}"
''
