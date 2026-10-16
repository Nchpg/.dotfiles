#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

if ! bat=$(find_battery); then
    emit "󰂑  N/A" "Batterie indisponible"
    exit 0
fi

capacity=$(<"$bat/capacity")
status=$(<"$bat/status")

icon=$(bat_icon "$capacity")

class=""
case "$status" in
    Charging)     icon=󰂄 ; class=charging ;;
    Full)         icon=󰁹 ;;
esac
if [[ $class != charging ]]; then
    if   (( capacity <= BATTERY_VERYLOW )); then class=critical
    elif (( capacity <= BATTERY_LOW )); then class=warning
    fi
fi

time_str=""
power_now=$(<"$bat/power_now")
energy_now=$(<"$bat/energy_now")
energy_full=$(<"$bat/energy_full")
if [[ $power_now =~ ^[0-9]+$ ]] && (( power_now > 0 )); then
    if [[ $status == Charging ]]; then
        remaining=$(( energy_full - energy_now ))
    else
        remaining=$energy_now
    fi
    if (( remaining > 0 )); then
        mins=$(( remaining * 60 / power_now ))
        time_str="$(( mins / 60 )) h $(printf '%02d' $(( mins % 60 ))) min"
    fi
fi

health=""
energy_full_design=$(<"$bat/energy_full_design")
if [[ $energy_full_design =~ ^[0-9]+$ ]] && (( energy_full_design > 0 )); then
    health=$(( (energy_full * 100 + energy_full_design / 2) / energy_full_design ))
fi
cycles=""
# Absent sur certaines batteries ; `read` plutôt que `cat` (script lancé toutes les 10 s)
[[ -r $bat/cycle_count ]] && read -r cycles <"$bat/cycle_count"

# Profil d'alimentation : busctl (~8 ms) plutôt que `powerprofilesctl` (Python, ~180 ms)
profile=""
ppd=$(busctl --system get-property org.freedesktop.UPower.PowerProfiles \
    /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles \
    ActiveProfile 2>/dev/null) || true
case "$ppd" in
    *'"performance"') profile="Performance" ;;
    *'"balanced"')    profile="Équilibré" ;;
    *'"power-saver"') profile="Économie" ;;
esac

# Ventilateurs : hwmon instable, on cherche l'acpi_fan dont fan1_input est
# numérique (deux existent). La « vitesse » ACPI de ce LG est fausse (10 000
# tr/min constants) : on n'affiche que marche/arrêt.
fan_rpm=""
for namefile in /sys/class/hwmon/hwmon*/name; do
    [[ $(<"$namefile") == acpi_fan ]] || continue
    v=""
    read -r v <"${namefile%/name}/fan1_input" 2>/dev/null || true
    [[ $v =~ ^[0-9]+$ ]] && { fan_rpm=$v; break; }
done
lg_fan_mode=""
read -r lg_fan_mode </sys/devices/platform/lg-laptop/fan_mode 2>/dev/null || true
case "$lg_fan_mode" in
    0) fan_mode="optimal" ;;
    1) fan_mode="silencieux" ;;
    2) fan_mode="performance" ;;
    *) fan_mode="" ;;
esac

tooltip="${capacity}%"
[[ -n "$time_str" ]] && tooltip+="  ·  ${time_str}"
[[ -n "$health" ]] && tooltip+=$'\n'"Santé ${health}%  ·  ${cycles} cycles"
[[ -n "$profile" ]] && tooltip+=$'\n'"Profil  ${profile}"
if [[ -n "$fan_rpm" ]]; then
    if (( fan_rpm > 0 )); then fan_line="en marche"; else fan_line="à l'arrêt"; fi
    [[ -n "$fan_mode" ]] && fan_line+=" · mode ${fan_mode}"
    tooltip+=$'\n'"Ventilateur  ${fan_line}"
fi

emit "${icon}  ${capacity}%" "$tooltip" "$class"
