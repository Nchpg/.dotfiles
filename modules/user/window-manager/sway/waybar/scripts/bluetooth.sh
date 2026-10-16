#!/usr/bin/env bash
set -euo pipefail

# busctl plutôt que bluetoothctl : chaque bluetoothctl s'enregistre auprès de
# bluetoothd (~23 000 lignes de journal par jour).

objects=$(busctl --system call org.bluez / org.freedesktop.DBus.ObjectManager \
    GetManagedObjects --json=short 2>/dev/null) || {
    emit "󰂯  N/A" ""
    exit 0
}

powered=$(jq -r '[.data[0][] | .["org.bluez.Adapter1"].Powered.data // empty]
    | any' <<<"$objects")
if [[ "$powered" != true ]]; then
    emit "󰂯  Off" ""
    exit 0
fi

# « batterie<US>nom » par ligne ; \x1f et pas une tabulation : bash fusionne les
# séparateurs blancs, une batterie vide décalerait le nom
connected_devices=$(jq -r '.data[0][]
    | select(.["org.bluez.Device1"].Connected.data == true)
    | "\(.["org.bluez.Battery1"].Percentage.data // "")\u001f\(.["org.bluez.Device1"].Alias.data)"' \
    <<<"$objects")
if [[ -z "$connected_devices" ]]; then
    emit "󰂯  On" ""
    exit 0
fi

MAX_BT_NAME_LENGTH=15
bar_list=""
tip_list=""

while IFS=$'\x1f' read -r battery_pct full_name; do
    [[ -z "$full_name" ]] && continue

    short_name=$full_name
    if [[ ${#short_name} -gt $MAX_BT_NAME_LENGTH ]]; then
        short_name="${short_name:0:$MAX_BT_NAME_LENGTH}..."
    fi

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

emit "󰂯  $bar_list" "$tip_list"
