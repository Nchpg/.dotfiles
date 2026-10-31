# focus-or-workspace left|right : fenêtre voisine, ou workspace précédent/suivant
# de la même sortie (en boucle) au bord. On y entre par le bord opposé.
dir=$1
back=left
step=next_on_output
if [ "$dir" = left ]; then
  back=right
  step=prev_on_output
fi

# « id x workspace » de la fenêtre focalisée.
focused() {
  swaymsg -t get_tree | jq -r '
    .. | objects | select(.type == "workspace") as $ws
    | $ws | .. | objects | select(.focused)
    | "\(.id) \(.rect.x) \($ws.name)"'
}

# Au bord, focus left/right repart à l'autre bout (focus_wrapping), ne bouge pas,
# ou passe sur une autre sortie : dans ces trois cas, on revient et on échoue.
try() {
  local id x ws nid nx nws
  read -r id x ws <<<"$(focused)"
  swaymsg -q "focus $1"
  read -r nid nx nws <<<"$(focused)"
  if [ "$nid" != "$id" ] && [ "$nws" = "$ws" ]; then
    if [ "$1" = right ] && [ "$nx" -gt "$x" ]; then return 0; fi
    if [ "$1" = left ] && [ "$nx" -lt "$x" ]; then return 0; fi
  fi
  swaymsg -q "[con_id=$id] focus"
  return 1
}

try "$dir" && exit 0

swaymsg -q "workspace $step"
for _ in 1 2 3 4 5 6 7 8; do
  try "$back" || break
done
