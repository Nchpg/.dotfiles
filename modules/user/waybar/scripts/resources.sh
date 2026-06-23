#!/usr/bin/env bash
# RAM / CPU / GPU — repris tel quel de sway-bar.sh.
# GPU Intel (driver xe) : pas de gpu_busy_percent en sysfs, on calcule le %
# occupé via le delta d'idle_residency_ms entre deux passages (état stocké).

cpu=$(top -bn1 | grep '^%Cpu' | awk '{print 100 - $8}')
mem_used=$(free | awk '/Mem:/ {printf("%.0f"), $3/$2 * 100}')

gpu() {
    idle_file=""
    for f in /sys/class/drm/card*/device/tile0/gt0/gtidle/idle_residency_ms; do
        [[ -r "$f" ]] && { idle_file="$f"; break; }
    done
    if [[ -z "$idle_file" ]]; then
        echo "GPU N/A"
        return
    fi

    state="${XDG_RUNTIME_DIR:-/tmp}/waybar-gpu.state"
    now_idle=$(<"$idle_file")
    now_ms=$(date +%s%3N)

    busy=0
    if [[ -r "$state" ]]; then
        read -r prev_idle prev_ms < "$state"
        d_idle=$((now_idle - prev_idle))
        d_ms=$((now_ms - prev_ms))
        if [[ "$d_ms" -gt 0 ]]; then
            busy=$(( (d_ms - d_idle) * 100 / d_ms ))
            (( busy < 0 )) && busy=0
            (( busy > 100 )) && busy=100
        fi
    fi
    echo "$now_idle $now_ms" > "$state"
    echo "GPU ${busy}%"
}

echo "󰍛   RAM : ${mem_used}%  CPU ${cpu%%.*}%  $(gpu)"
