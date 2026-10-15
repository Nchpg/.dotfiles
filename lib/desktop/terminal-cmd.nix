# Lance un programme dans le terminal par défaut de l'utilisateur
# (userSettings.terminal.default, lu ici une fois pour tous les appelants).
# alacritty exige `-e`, kitty/foot l'acceptent tel quel.
#
# `title` est facultatif : il ne sert que si un for_window sway doit matcher
# la fenêtre (TUIs flottants, cf. floating-tui-launcher.nix). Le tmux de
# Ctrl+Entrée ou le btop du clic waybar s'en passent.
lib:
{
  config,
  exec, # programme (+ arguments) à lancer
  title ? null, # titre de fenêtre passé à --title ; null = aucun
  kittyExtraOpts ? "", # options kitty seulement (ex. kittyQuit, padding) ; "" = aucune
}:
let
  term = config.userSettings.terminal.default;
  extra = lib.optionalString (term == "kitty" && kittyExtraOpts != "") "${kittyExtraOpts} ";
  # Échappé par défense : tous les appels actuels passent un titre sans
  # espace, mais rien ne garantit que ça reste vrai.
  titleOpt = lib.optionalString (title != null) "--title ${lib.escapeShellArg title} ";
in
if term == "alacritty" then
  "${term} ${titleOpt}-e ${exec}"
else
  "${term} ${extra}${titleOpt}${exec}"
