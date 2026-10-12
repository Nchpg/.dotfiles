#!/usr/bin/env bash
set -euo pipefail
# État du tunnel WireGuard vers la maison. Trois états distincts, parce que
# « l'interface existe » ne veut pas dire « ça marche » : le tunnel démarre au
# boot (autostart), donc il est présent même quand le serveur est éteint, et
# c'est justement ce cas-là qu'on veut voir.
#
# La joignabilité se teste par une CONNEXION TCP sur le 443 du serveur et non
# par ping : le module s'exécute sans privilège, et un socket TCP ne demande
# rien de particulier là où l'ICMP dépend de `ping_group_range`. Le 443 est de
# toute façon le port qui nous intéresse — c'est celui que Nextcloud emprunte.
#
# json_escape : fourni par lib.sh (inliné en tête au build). On n'utilise pas
# `emit`, qui n'émet pas de classe CSS — même approche que weather.sh : l'état
# est ce qui compte ici, il doit se voir à la couleur sans lire l'infobulle.

export LC_ALL=C

iface=wg0
peer=10.8.0.1

# État publié par vpn-alert (modules/user/window-manager/sway/notifications),
# qui sonde déjà le tunnel toutes les 15 s et réveille ce module par signal :
# inutile de refaire la même connexion TCP ici. Ligne « epoch état adresse ».
# Repli sur la sonde locale si l'état manque ou date (pas de client VPN, timer
# arrêté) : au-delà de 45 s, il ne reflète plus le présent.
state_file="${XDG_RUNTIME_DIR:-/tmp}/vpn-alert/state"

# $1 = texte, $2 = infobulle, $3 = classe CSS
emit_class() {
    local t tt
    json_escape_to t "$1"
    json_escape_to tt "$2"
    printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$t" "$3" "$tt"
}

state="" addr=""
printf -v now '%(%s)T' -1
if read -r ts st a <"$state_file" 2>/dev/null && [[ $ts =~ ^[0-9]+$ ]] && ((now - ts < 45)); then
    state=$st addr=$a
elif [ ! -d "/sys/class/net/$iface" ]; then
    state=off
else
    addr=$(ip -4 -brief addr show "$iface" 2>/dev/null | awk '{print $3}')
    # `exec 3<>` plutôt qu'un simple test : ouvre puis referme proprement,
    # sans laisser de descripteur derrière à chaque passage.
    if timeout 1 bash -c "exec 3<>/dev/tcp/$peer/443" 2>/dev/null; then
        state=on
    else
        state=down
    fi
fi
[ -n "$addr" ] || addr="sans adresse"

if [ "$state" = off ]; then
    tip="Tunnel non monté"
    tip+=$'\n'
    tip+=$'\n'"sudo systemctl start wg-quick-$iface"
    emit_class "󰖂  Off" "$tip" off
    exit 0
fi

if [ "$state" = on ]; then
    tip="Tunnel actif : $addr"
    tip+=$'\n'"Serveur $peer joignable"
    emit_class "󰖂  On" "$tip" on
else
    tip="Tunnel monté ($addr) mais $peer ne répond pas."
    tip+=$'\n'"Serveur éteint, ou poignée de main échouée."
    tip+=$'\n'
    tip+=$'\n'"Le reste du trafic n'est pas affecté : seul"
    tip+=$'\n'"10.8.0.0/24 passe par le tunnel."
    emit_class "󰖂  ?" "$tip" unreachable
fi
