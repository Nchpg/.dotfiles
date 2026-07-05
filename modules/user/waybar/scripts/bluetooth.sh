#!/usr/bin/env bash
# État Bluetooth + appareils connectés. Sortie JSON :
#   - barre   : icône + noms TRONQUÉS (15 car.) + batterie
#   - tooltip : noms COMPLETS + batterie, un par ligne
# Logique reprise de sway-bar.sh.

# Force la locale C : les libellés grepés ('Powered: yes', 'Battery
# Percentage') sont en anglais, on ne dépend pas de la locale de session.
export LC_ALL=C

# Icônes batterie Nerd Font (Material Design) : mêmes 11 niveaux que le module
# batterie du PC (codepoints f008e..f0079, cf. format-icons dans waybar
# default.nix -> garder les DEUX listes synchronisées). Index = pourcentage
# arrondi à la dizaine (0% -> outline 󰂎 ... 100% -> pleine 󰁹). Glyphes
# littéraux (et non printf '\U…') : insensibles à LC_ALL=C, qui en locale ASCII
# ne sait pas encoder ces codepoints du plan astral.
bat_icons=(󰂎 󰁺 󰁻 󰁼 󰁽 󰁾 󰁿 󰂀 󰂁 󰂂 󰁹)
bat_icon() { # $1 = pourcentage -> glyphe
    local idx=$(( ($1 + 5) / 10 ))
    (( idx < 0 )) && idx=0
    (( idx > 10 )) && idx=10
    printf '%s' "${bat_icons[idx]}"
}

# json_escape / emit : fournis par lib.sh (inliné en tête au build).

if ! command -v bluetoothctl &>/dev/null; then
    emit "󰂯  N/A" ""
    exit 0
fi

powered=$(bluetoothctl show | grep -E 'Powered: yes')
if [[ -z "$powered" ]]; then
    emit "󰂯  Off" ""
    exit 0
fi

# bluetoothctl injecte des codes ANSI : on les retire (sinon troncature parasite).
connected_devices=$(bluetoothctl devices Connected | sed 's/\x1b\[[0-9;]*m//g')
if [[ -z "$connected_devices" ]]; then
    emit "󰂯  On" ""
    exit 0
fi

MAX_BT_NAME_LENGTH=15
bar_list=""  # noms tronqués (barre)
tip_list=""  # noms complets (tooltip), séparés par de vraies nouvelles lignes

# Format des lignes : « Device AA:BB:CC:DD:EE:FF Nom de l'appareil ». On
# découpe en bash (read) : _ = "Device", mac = adresse, full_name = le reste.
while read -r _ mac full_name; do
    [[ -z "$mac" ]] && continue

    short_name=$full_name
    if [[ ${#short_name} -gt $MAX_BT_NAME_LENGTH ]]; then
        short_name="${short_name:0:$MAX_BT_NAME_LENGTH}..."
    fi

    # Suffixe batterie (icône dynamique + %), identique barre et tooltip.
    battery_pct=$(bluetoothctl info "$mac" 2>/dev/null \
        | grep -i 'Battery Percentage' | grep -oP '\(\K[0-9]+')
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
