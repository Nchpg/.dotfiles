#!/usr/bin/env bash
set -euo pipefail
# Module luminosité (custom) : affiche le % de rétroéclairage, et son ICÔNE
# reflète l'état du night light (service wlsunset) — lune si actif, glyphe
# luminosité sinon. La couleur reste fixe (orange, cf. CSS). On émet la
# catégorie on/off dans "alt", mappée sur l'icône côté Nix (format-icons).
# Molette = luminosité, clic = bascule night light (cf. default.nix).
export LC_ALL=C

pct=$(brightnessctl -m 2>/dev/null | cut -d, -f4) || true # ex. "42%"

# Pas de périphérique de rétroéclairage (desktop, écran externe sans DDC...) :
# même repli N/A que battery.sh/bluetooth.sh plutôt qu'un champ texte vide.
if [[ -z "$pct" ]]; then
    printf '{"text":"N/A","tooltip":"Rétroéclairage indisponible"}\n'
    exit 0
fi

if systemctl --user is-active --quiet wlsunset; then
    alt=on
    tip="Night light activé"
else
    alt=off
    tip="Night light désactivé"
fi

printf '{"text":"%s","alt":"%s","tooltip":"%s"}\n' "$pct" "$alt" "$tip"
