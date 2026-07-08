#!/usr/bin/env bash
# Envoie un message Discord (via webhook) résumant le run du workflow
# weekly-update : succès/échec, lien vers le run, et s'il y a eu un
# changement de version de noyau (fichier facts.json optionnel, absent si le
# job a échoué avant de l'écrire).
#
# Usage: notify-discord.sh <status: success|failure|cancelled> <run-url> [facts.json]
# Nécessite DISCORD_WEBHOOK_URL dans l'environnement.
set -euo pipefail

status="$1"
run_url="$2"
facts_file="${3:-}"

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    echo "DISCORD_WEBHOOK_URL absent, notification ignorée" >&2
    exit 0
fi

case "$status" in
success) emoji="✅" ;;
failure) emoji="❌" ;;
*) emoji="⚠️" ;;
esac

content="${emoji} weekly-update (${status}) — ${run_url}"

if [ -n "$facts_file" ] && [ -f "$facts_file" ]; then
    kernel_changed=$(jq '[.flakeInputs[] | select(.kernelChanged == true)] | length > 0' "$facts_file")
    if [ "$kernel_changed" = "true" ]; then
        kernel_line=$(jq -r '.flakeInputs[] | select(.kernelChanged == true) |
          "noyau: \(.oldKernelVersion) → \(.newKernelVersion)"' "$facts_file")
        content="${content}
⚠️ ${kernel_line}"
    fi
fi

jq -n --arg content "$content" '{content: $content}' \
    | curl -sf -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL" >/dev/null
