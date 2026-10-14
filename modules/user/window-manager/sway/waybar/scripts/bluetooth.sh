#!/usr/bin/env bash
set -euo pipefail
# État Bluetooth + appareils connectés. Sortie JSON :
#   - barre   : icône + noms TRONQUÉS (15 car.) + batterie
#   - tooltip : noms COMPLETS + batterie, un par ligne

# Un SEUL appel D-Bus en lecture (busctl) plutôt que 2-3 `bluetoothctl` par
# tour : chaque bluetoothctl s'enregistre auprès de bluetoothd (moniteur
# d'annonces), ~23 000 lignes « Adv Monitor app reserved/disconnected » dans
# le journal par jour avec un tour toutes les 5 s.

# emit / bat_icon : fournis par lib.sh (inliné en tête au build).

objects=$(busctl --system call org.bluez / org.freedesktop.DBus.ObjectManager \
    GetManagedObjects --json=short 2>/dev/null) || {
    emit "󰂯  N/A" "" # bluetoothd absent ou arrêté
    exit 0
}

# Adaptateur allumé ? (au moins un Adapter1 avec Powered = true)
powered=$(jq -r '[.data[0][] | .["org.bluez.Adapter1"].Powered.data // empty]
    | any' <<<"$objects")
if [[ "$powered" != true ]]; then
    emit "󰂯  Off" ""
    exit 0
fi

# Appareils connectés, un par ligne : « batterie<US>nom » (batterie vide si
# non reportée). Séparateur \x1f (unit separator) et pas une tabulation :
# bash fusionne les séparateurs blancs, une batterie vide décalerait le nom.
connected_devices=$(jq -r '.data[0][]
    | select(.["org.bluez.Device1"].Connected.data == true)
    | "\(.["org.bluez.Battery1"].Percentage.data // "")\u001f\(.["org.bluez.Device1"].Alias.data)"' \
    <<<"$objects")
if [[ -z "$connected_devices" ]]; then
    emit "󰂯  On" ""
    exit 0
fi

MAX_BT_NAME_LENGTH=15
bar_list=""  # noms tronqués (barre)
tip_list=""  # noms complets (tooltip), séparés par de vraies nouvelles lignes

while IFS=$'\x1f' read -r battery_pct full_name; do
    [[ -z "$full_name" ]] && continue

    short_name=$full_name
    if [[ ${#short_name} -gt $MAX_BT_NAME_LENGTH ]]; then
        short_name="${short_name:0:$MAX_BT_NAME_LENGTH}..."
    fi

    # Suffixe batterie (icône dynamique + %), identique barre et tooltip.
    suffix=""
    [[ -n "$battery_pct" ]] && suffix="  $(bat_icon "$battery_pct")  ${battery_pct}%"

    if [[ -z "$bar_list" ]]; then
        bar_list="${short_name}${suffix}"
        tip_list="${full_name}${suffix}"
    else
        bar_list="$bar_list  •  ${short_name}${suffix}"
        tip_list="$tip_list"$'\n'"${full_name}${suffix}"
    fi
done <<< "$connected_devices"

# Au moins un appareil connecté : le nom + batterie parle de lui-même, on
# laisse tomber le « On : » redondant.
emit "󰂯  $bar_list" "$tip_list"
