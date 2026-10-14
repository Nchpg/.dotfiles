#!/usr/bin/env bash
set -euo pipefail
# État du tunnel WireGuard vers la maison. Trois états distincts, parce que
# « l'interface existe » ne veut pas dire « ça marche » : le tunnel démarre au
# boot (autostart), donc il est présent même quand le serveur est éteint, et
# c'est justement ce cas-là qu'on veut voir.
#
# Aucune sonde ici : vpn-alert (sway/notifications), SEULE sonde du tunnel,
# teste le serveur toutes les 15 s, publie l'état et réveille ce module par
# signal. Ligne « epoch état adresse ». Au-delà de 45 s, l'état ne reflète
# plus le présent (timer arrêté, pas de client VPN) : repli « inconnu », sauf
# interface absente, qui se lit sans rien sonder.
#
# Paramètres posés par scripts.nix depuis la config du client VPN : VPN_IFACE,
# VPN_PEER, VPN_ROUTED. emit vient de lib.sh : l'état est ce qui compte ici, il
# doit se voir à la couleur (classe CSS) sans lire l'infobulle.

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
