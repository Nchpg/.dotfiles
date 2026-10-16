#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

pct=$(brightnessctl -m 2>/dev/null | cut -d, -f4) || true

if [[ -z "$pct" ]]; then
    emit "N/A" "Rétroéclairage indisponible"
    exit 0
fi

if systemctl --user is-active --quiet wlsunset; then
    alt=on
    tip="Night light activé"
else
    alt=off
    tip="Night light désactivé"
fi

emit "$pct" "$tip" "" "$alt"
