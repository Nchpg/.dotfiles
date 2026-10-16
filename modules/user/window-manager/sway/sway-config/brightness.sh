# shellcheck shell=bash
# Jamais 0 % (écran noir)

steps=(1 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100)

usage() {
  echo "usage: brightness up|down|set N" >&2
  exit 1
}

current=$(brightnessctl get)
max=$(brightnessctl max)
percent=$((100 * current / max))

case "${1:-}" in
  down)
    for ((i = ${#steps[@]} - 1; i >= 0; i--)); do
      if [ "${steps[i]}" -lt "$percent" ]; then
        brightnessctl set "${steps[i]}%" >/dev/null
        break
      fi
    done
    ;;
  up)
    for step in "${steps[@]}"; do
      if [ "$step" -gt "$percent" ]; then
        brightnessctl set "${step}%" >/dev/null
        break
      fi
    done
    ;;
  set)
    [[ ${2:-} =~ ^[0-9]+$ ]] || usage
    n=$2
    ((n < 1)) && n=1
    ((n > 100)) && n=100
    brightnessctl set "${n}%" >/dev/null
    ;;
  *) usage ;;
esac

pkill -RTMIN+"$WAYBAR_BACKLIGHT_SIGNAL" waybar 2>/dev/null || true
