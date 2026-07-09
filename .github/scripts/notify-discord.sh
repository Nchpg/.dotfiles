#!/usr/bin/env bash
# Envoie un message Discord (via webhook) résumant le run du workflow
# weekly-update : ping l'utilisateur (notif garantie), succès/échec, alerte
# noyau, puis lien de la PR et sa description en dessous (si une PR a été
# créée). Volontairement minimal : pas de lien vers le run GitHub Actions ni
# de liens de comparaison dans la description, seulement le lien PR (avec
# preview Discord désactivée via <>) pour éviter le bruit des embeds.
#
# Toute la config passe par variables d'environnement (pas d'arguments
# positionnels) :
#   DISCORD_WEBHOOK_URL  requis
#   DISCORD_USER_ID       requis (ping l'utilisateur, sinon pas de notif fiable)
#   STATUS                requis : success|failure|cancelled
#   PR_URL                 optionnel : lien de la PR créée
#   PR_BODY_FILE           optionnel : fichier markdown de la description de la PR
#   FACTS_FILE             optionnel : facts.json (pour l'alerte noyau)
set -euo pipefail

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    echo "DISCORD_WEBHOOK_URL absent, notification ignorée" >&2
    exit 0
fi

status="${STATUS:?STATUS requis}"

case "$status" in
success) emoji="✅" ;;
failure) emoji="❌" ;;
*) emoji="⚠️" ;;
esac

mention=""
if [ -n "${DISCORD_USER_ID:-}" ]; then
    mention="<@${DISCORD_USER_ID}> "
fi

content="${mention}${emoji} weekly-update (${status})"

if [ -n "${FACTS_FILE:-}" ] && [ -f "$FACTS_FILE" ]; then
    kernel_changed=$(jq '[.flakeInputs[] | select(.kernelChanged == true)] | length > 0' "$FACTS_FILE")
    if [ "$kernel_changed" = "true" ]; then
        kernel_line=$(jq -r '.flakeInputs[] | select(.kernelChanged == true) |
          "noyau: \(.oldKernelVersion) → \(.newKernelVersion)"' "$FACTS_FILE")
        content="${content}
⚠️ ${kernel_line}"
    fi
fi

if [ -n "${PR_URL:-}" ]; then
    content="${content}

<${PR_URL}>"
    if [ -n "${PR_BODY_FILE:-}" ] && [ -f "$PR_BODY_FILE" ]; then
        content="${content}

$(cat "$PR_BODY_FILE")"
    fi
fi

# Discord limite le contenu d'un message à 2000 caractères.
content="${content:0:2000}"

jq -n --arg content "$content" '{content: $content}' \
    | curl -sf -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL" >/dev/null
