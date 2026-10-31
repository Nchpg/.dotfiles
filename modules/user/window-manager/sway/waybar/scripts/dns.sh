#!/usr/bin/env bash
set -euo pipefail
# DNS privé (service système private-dns) : affiche l'état, ou bascule avec « toggle ».
# polkit autorise les admins à démarrer et arrêter ce service sans mot de passe.

if [ "${1:-}" = toggle ]; then
    if systemctl is-active --quiet private-dns.service; then
        systemctl stop private-dns.service
    else
        systemctl start private-dns.service
    fi
    pkill -RTMIN+"$WAYBAR_DNS_SIGNAL" waybar || true
    exit 0
fi

if systemctl is-active --quiet private-dns.service; then
    tip="DNS privé : $DNS_HOST (DNS-over-TLS)"
    tip+=$'\n'"Pubs et pisteurs bloqués"
    tip+=$'\n'
    tip+=$'\n'"Clic : revenir au DNS du réseau (portail captif)"
    emit "󰒃  On" "$tip" on
else
    tip="DNS du réseau, en clair"
    tip+=$'\n'
    tip+=$'\n'"Clic : DNS privé $DNS_HOST"
    emit "󰒃  Off" "$tip" off
fi
