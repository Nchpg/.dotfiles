#!/usr/bin/env bash
# État Bluetooth + appareils connectés (nom tronqué + batterie si rapportée).
# Logique reprise telle quelle de sway-bar.sh.

if ! command -v bluetoothctl &>/dev/null; then
    echo "󰂯  N/A"
    exit 0
fi

powered=$(bluetoothctl show | grep -E 'Powered: yes')
if [[ -z "$powered" ]]; then
    echo "󰂯  Off"
    exit 0
fi

# bluetoothctl injecte des codes ANSI : on les retire (sinon troncature parasite).
connected_devices=$(bluetoothctl devices Connected | sed 's/\x1b\[[0-9;]*m//g')
if [[ -z "$connected_devices" ]]; then
    echo "󰂯  On"
    exit 0
fi

MAX_BT_NAME_LENGTH=15
device_list=""

while IFS= read -r line; do
    mac=$(echo "$line" | awk '{print $2}')
    device_name=$(echo "$line" | awk '{ $1=""; $2=""; print $0 }' | xargs)

    if [[ ${#device_name} -gt $MAX_BT_NAME_LENGTH ]]; then
        device_name="${device_name:0:$MAX_BT_NAME_LENGTH}..."
    fi

    battery_pct=$(bluetoothctl info "$mac" 2>/dev/null \
        | grep -i 'Battery Percentage' | grep -oP '\(\K[0-9]+')
    if [[ -n "$battery_pct" ]]; then
        device_name="$device_name 󰁹   ${battery_pct}%"
    fi

    if [[ -z "$device_list" ]]; then
        device_list="$device_name"
    else
        device_list="$device_list, $device_name"
    fi
done <<< "$connected_devices"

echo "󰂯  On : $device_list"
