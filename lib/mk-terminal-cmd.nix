# Commande de lancement d'un programme dans le terminal par défaut de
# l'utilisateur, dans une fenêtre titrée (matchée ensuite par un for_window
# sway). alacritty exige `-e` pour lancer un programme direct ; kitty et foot
# l'acceptent tel quel. Pattern répété à l'identique dans bluetooth-picker,
# calendar-tui, lg-control, systemd-manager-tui, task-tui, volume-mixer,
# wifi-picker — seuls le titre, la commande et d'éventuelles options kitty
# changent.
{
  lib,
  term, # config.userSettings.terminal.default
  title, # titre de fenêtre passé à --title
  exec, # programme (+ arguments) à lancer
  kittyExtraOpts ? "", # options kitty seulement (ex. kittyQuit, padding) ; "" = aucune
}:
let
  extra = lib.optionalString (term == "kitty" && kittyExtraOpts != "") "${kittyExtraOpts} ";
in
if term == "alacritty" then
  "${term} --title ${title} -e ${exec}"
else
  "${term} ${extra}--title ${title} ${exec}"
