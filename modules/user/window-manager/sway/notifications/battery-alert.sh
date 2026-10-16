# shellcheck shell=bash

bat=$(find_battery) || exit 0

cap=$(cat "$bat/capacity")
status=$(cat "$bat/status")
state="${XDG_RUNTIME_DIR:-/tmp}/battery-alert.state"
last=$(cat "$state" 2>/dev/null || echo ok)

bucket=ok; urgency=normal; icon="$ICON_LOW"; title=""; body=""
if [ "$cap" -le "$CRIT" ]; then
  bucket=crit; urgency=critical; icon="$ICON_CAUTION"
  title="Batterie critique"; body="Batterie à $cap% — branche le chargeur !"
elif [ "$cap" -le "$VERYLOW" ]; then
  bucket=verylow; urgency=critical; icon="$ICON_VERYLOW"
  title="Batterie très faible"; body="Batterie à $cap%"
elif [ "$cap" -le "$LOW" ]; then
  bucket=low; urgency=normal; icon="$ICON_LOW"
  title="Batterie faible"; body="Batterie à $cap%"
fi

# -h ...:battery remplace la notif précédente au lieu d'empiler.
if [ "$status" = "Discharging" ] && [ "$bucket" != ok ]; then
  if [ "$bucket" != "$last" ]; then
    notify-send -u "$urgency" -i "$icon" \
      -h string:x-canonical-private-synchronous:battery \
      "$title" "$body"
  fi
  echo "$bucket" > "$state"
else
  echo ok > "$state"
fi
