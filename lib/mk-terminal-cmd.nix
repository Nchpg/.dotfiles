# Lance un programme dans le terminal par défaut, fenêtre titrée (matchée
# par un for_window sway). alacritty exige `-e`, kitty/foot l'acceptent tel quel.
{
  lib,
  term, # config.userSettings.terminal.default
  title, # titre de fenêtre passé à --title
  exec, # programme (+ arguments) à lancer
  kittyExtraOpts ? "", # options kitty seulement (ex. kittyQuit, padding) ; "" = aucune
}:
let
  extra = lib.optionalString (term == "kitty" && kittyExtraOpts != "") "${kittyExtraOpts} ";
  # Échappé par défense : tous les appels actuels passent un titre sans
  # espace, mais rien ne garantit que ça reste vrai.
  safeTitle = lib.escapeShellArg title;
in
if term == "alacritty" then
  "${term} --title ${safeTitle} -e ${exec}"
else
  "${term} ${extra}--title ${safeTitle} ${exec}"
