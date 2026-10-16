#!/usr/bin/env bash
set -euo pipefail
# « interface présente » ne veut pas dire « ça marche ». Lit la ligne publiée par
# vpn-alert ; périmée au-delà de 45 s (repli « inconnu », sauf interface absente).

export LC_ALL=C

state_file="${XDG_RUNTIME_DIR:-/tmp}/vpn-alert/state"

state="" addr=""
printf -v now '%(%s)T' -1
if read -r ts st a <"$state_file" 2>/dev/null && [[ $ts =~ ^[0-9]+$ ]] && ((now - ts < 45)); then
    state=$st addr=${a:-}
elif [ ! -d "/sys/class/net/$VPN_IFACE" ]; then
    state=off
else
    state=unknown
fi
[ -n "$addr" ] || addr="sans adresse"

case "$state" in
    off)
        tip="Tunnel non monté"
        tip+=$'\n'
        tip+=$'\n'"sudo systemctl start wg-quick-$VPN_IFACE"
        emit "󰖂  Off" "$tip" off
        ;;
    on)
        tip="Tunnel actif : $addr"
        tip+=$'\n'"Serveur $VPN_PEER joignable"
        emit "󰖂  On" "$tip" on
        ;;
    down)
        tip="Tunnel monté ($addr) mais $VPN_PEER ne répond pas."
        tip+=$'\n'"Serveur éteint, ou poignée de main échouée."
        tip+=$'\n'
        tip+=$'\n'"Le reste du trafic n'est pas affecté : seul"
        tip+=$'\n'"$VPN_ROUTED passe par le tunnel."
        emit "󰖂  ?" "$tip" unreachable
        ;;
    *)
        tip="État du tunnel inconnu : pas de relevé récent de vpn-alert."
        tip+=$'\n'
        tip+=$'\n'"systemctl --user status vpn-alert.timer"
        emit "󰖂  ?" "$tip"
        ;;
esac
