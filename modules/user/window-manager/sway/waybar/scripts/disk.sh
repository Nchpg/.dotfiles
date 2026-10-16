#!/usr/bin/env bash
set -euo pipefail
# Le total affiché est l'espace utilisable (utilisé + libre), hors blocs réservés à root.

export LC_ALL=C

read -r size_b used_b avail_b pct < <(
    df -B1 --output=size,used,avail,pcent / | tail -1
)
usable_b=$((used_b + avail_b))

fmt() { numfmt --to=iec "$1"; }

used_h=$(fmt "$used_b")
avail_h=$(fmt "$avail_b")
usable_h=$(fmt "$usable_b")
size_h=$(fmt "$size_b")

# Réserve root dérivée des valeurs affichées (arrondies au supérieur comme numfmt),
# sinon usable + réserve ≠ partition à l'écran
g=$((1024 * 1024 * 1024))
reserve_g=$(( (size_b + g - 1) / g - (usable_b + g - 1) / g ))

text="󰉋   ${used_h}o : ${pct}"
tooltip="Utilisé    ${used_h}o / ${usable_h}o  (${pct})"
tooltip+=$'\n'"Libre      ${avail_h}o"
tooltip+=$'\n'"Partition  ${size_h}o  (réserve root ${reserve_g}Go)"

# Santé NVMe publiée par le service système nvme-health-export (smartctl exige root)
set -- /run/nvme-health/nvme*.json
health="$1"
if [ -e "$health" ]; then
    read -r temp wear spare written hours status < <(
        jq -r '[
            .temperature.current,
            .nvme_smart_health_information_log.percentage_used,
            .nvme_smart_health_information_log.available_spare,
            # data units NVMe = blocs de 512 000 octets
            (.nvme_smart_health_information_log.data_units_written * 512000),
            .power_on_time.hours,
            (if .smart_status.passed then "OK" else "DÉFAILLANT" end)
        ] | @tsv' "$health" 2>/dev/null
    ) || true
    if [ -n "${temp:-}" ] && [ "$temp" != "null" ]; then
        written_h=$(numfmt --to=si --round=nearest "$written")
        tooltip+=$'\n'
        tooltip+=$'\n'"NVMe       ${temp}°C · santé ${status}"
        tooltip+=$'\n'"Usure      ${wear}%  (spare ${spare}%)"
        tooltip+=$'\n'"Écrit      ${written_h}o · ${hours} h"
    fi
fi

emit "$text" "$tooltip"
