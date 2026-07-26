#!/usr/bin/env bash
set -euo pipefail
# Lancé par le service systemd wlsunset (cf. default.nix). Récupère la ville
# météo courante et SES coordonnées (cache partagé avec weather.sh via lib.sh),
# pour que le night light suive le même lieu que la météo. Repli sur Angers si
# le géocodage est indisponible. `exec` : wlsunset remplace ce process, donc
# systemd suit directement le démon.
export LC_ALL=C

read -r lat lon <<<"$(weather_coords "$(weather_city)")"
[[ -z "$lat" ]] && { lat=47.47; lon=-0.55; } # Angers par défaut

exec wlsunset -l "$lat" -L "$lon" -t 3800 -T 6500
