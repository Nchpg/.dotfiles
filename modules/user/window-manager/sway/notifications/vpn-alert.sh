# shellcheck shell=bash
# (Pas de shebang : writeShellApplication l'ajoute, avec set -euo pipefail.)
#
# Tunnel vers le serveur (cf. systemSettings.vpn.client) : SEULE sonde du
# tunnel de la session. Prévient quand le serveur cesse de répondre, et quand
# il revient, et publie l'état pour la case vpn de waybar (qui ne sonde plus
# rien elle-même). Dans un service à part et pas dans waybar : waybar lance
# son script une fois PAR ÉCRAN, les notifs seraient doublées.
#
# Joignabilité testée par une CONNEXION TCP sur le port du serveur et non par
# ping : le service tourne sans privilège, et un socket TCP ne demande rien de
# particulier là où l'ICMP dépend de `ping_group_range`.
#
# Un changement d'état n'est notifié qu'une fois confirmé : au réveil, le
# réseau met quelques secondes à revenir, et un seul échec déclencherait une
# fausse alerte suivie d'un « rétabli ».
#
# Paramètres posés par le module (runtimeEnv) : VPN_IFACE, VPN_PEER,
# VPN_PORT, WAYBAR_VPN_SIGNAL, ICON_DOWN, ICON_OFF, ICON_ON.

dir="${XDG_RUNTIME_DIR:-/tmp}/vpn-alert"
mkdir -p "$dir"

addr=""
if [ ! -d "/sys/class/net/$VPN_IFACE" ]; then
  now=off
else
  read -r _ _ addr _ < <(ip -4 -brief addr show "$VPN_IFACE" 2>/dev/null) || true
  # `exec 3<>` plutôt qu'un simple test : ouvre puis referme proprement,
  # sans laisser de descripteur derrière à chaque passage.
  if timeout 2 bash -c "exec 3<>/dev/tcp/$VPN_PEER/$VPN_PORT" 2>/dev/null; then
    now=on
  else
    now=down
  fi
fi

# État brut publié pour le module vpn de waybar (« epoch état adresse »),
# réveillé par signal.
printf -v epoch '%(%s)T' -1
printf '%s %s %s\n' "$epoch" "$now" "$addr" > "$dir/state.tmp"
mv -f "$dir/state.tmp" "$dir/state"
pkill -RTMIN+"$WAYBAR_VPN_SIGNAL" waybar 2>/dev/null || true

shown=$(cat "$dir/shown" 2>/dev/null || echo "")
pending=$(cat "$dir/pending" 2>/dev/null || echo "")

# Premier passage de la session : on prend l'état tel quel, sans notif.
if [ -z "$shown" ]; then
  echo "$now" > "$dir/shown"
  exit 0
fi

if [ "$now" = "$shown" ]; then
  rm -f "$dir/pending"
  exit 0
fi
# Notifie un changement seulement s'il tient 30 s (sonde toutes les
# 15 s) : une coupure d'un instant ne mérite pas d'alerte. « état epoch ».
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
