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

# $1 = texte, $2 = infobulle, $3 = classe CSS
emit_class() {
    printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' \
        "$(json_escape "$1")" "$3" "$(json_escape "$2")"
}

if [ ! -d "/sys/class/net/$iface" ]; then
    tip="Tunnel non monté"
    tip+=$'\n'
    tip+=$'\n'"sudo systemctl start wg-quick-$iface"
    emit_class "󰖂  Off" "$tip" off
    exit 0
fi

addr=$(ip -4 -brief addr show "$iface" 2>/dev/null | awk '{print $3}')
[ -n "$addr" ] || addr="sans adresse"

# `exec 3<>` plutôt qu'un simple test : ouvre puis referme proprement, sans
# laisser de descripteur derrière à chaque passage.
if timeout 1 bash -c "exec 3<>/dev/tcp/$peer/443" 2>/dev/null; then
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
