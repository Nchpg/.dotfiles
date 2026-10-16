# shellcheck shell=bash
# SEULE sonde du tunnel (waybar lancerait son script une fois par écran : notifs
# doublées). TCP et non ping : pas de privilège requis.

dir="${XDG_RUNTIME_DIR:-/tmp}/vpn-alert"
mkdir -p "$dir"

addr=""
if [ ! -d "/sys/class/net/$VPN_IFACE" ]; then
  now=off
else
  read -r _ _ addr _ < <(ip -4 -brief addr show "$VPN_IFACE" 2>/dev/null) || true
  if timeout 2 bash -c "exec 3<>/dev/tcp/$VPN_PEER/$VPN_PORT" 2>/dev/null; then
    now=on
  else
    now=down
  fi
fi

# « epoch état adresse », lu par le module vpn de waybar
printf -v epoch '%(%s)T' -1
printf '%s %s %s\n' "$epoch" "$now" "$addr" > "$dir/state.tmp"
mv -f "$dir/state.tmp" "$dir/state"
pkill -RTMIN+"$WAYBAR_VPN_SIGNAL" waybar 2>/dev/null || true

shown=$(cat "$dir/shown" 2>/dev/null || echo "")
pending=$(cat "$dir/pending" 2>/dev/null || echo "")

if [ -z "$shown" ]; then
  echo "$now" > "$dir/shown"
  exit 0
fi

if [ "$now" = "$shown" ]; then
  rm -f "$dir/pending"
  exit 0
fi
# Notifié seulement s'il tient 30 s (« état epoch ») : le réseau met du temps à revenir au réveil
pending_state="" pending_since=""
read -r pending_state pending_since <<<"$pending" || true
if [ "$now" != "$pending_state" ] || [ -z "$pending_since" ]; then
  echo "$now $epoch" > "$dir/pending"
  exit 0
fi
if [ $((epoch - pending_since)) -lt 30 ]; then
  exit 0
fi

rm -f "$dir/pending"
echo "$now" > "$dir/shown"
sync=string:x-canonical-private-synchronous:vpn
case "$now" in
  down) notify-send -u normal -i "$ICON_DOWN" -h "$sync" "VPN : think injoignable" \
          "Le tunnel est monté mais $VPN_PEER ne répond plus. Nextcloud ne synchronise pas." ;;
  off)  notify-send -u normal -i "$ICON_OFF" -h "$sync" "VPN : tunnel arrêté" \
          "$VPN_IFACE n'existe plus. sudo systemctl start wg-quick-$VPN_IFACE" ;;
  on)   notify-send -u normal -i "$ICON_ON" -h "$sync" "VPN : think joignable" "Le tunnel fonctionne de nouveau." ;;
esac
