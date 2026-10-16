#!/usr/bin/env bash
# Env : DISCORD_WEBHOOK_URL, DISCORD_USER_ID, STATUS (success, failure, cancelled) requis ; PR_URL, PR_BODY_FILE, FACTS_FILE, RUN_URL optionnels.
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

# -s et pas -f : un facts.json vide (step en échec) ferait tuer l'alerte d'échec par jq sous `set -e`.
if [ -n "${FACTS_FILE:-}" ] && [ -s "$FACTS_FILE" ]; then
    kernel_count=$(jq '.kernelChanges // [] | length' "$FACTS_FILE" 2>/dev/null || echo 0)
    if [ "$kernel_count" -gt 0 ]; then
        kernel_line=$(jq -r '.kernelChanges[] | "noyau: \(.from) → \(.to)"' "$FACTS_FILE")
        content="${content}
⚠️ ${kernel_line}"
    fi

    skipped_count=$(jq '.skippedExtensions // [] | length' "$FACTS_FILE" 2>/dev/null || echo 0)
    if [ "$skipped_count" -gt 0 ]; then
        skipped_keys=$(jq -r '[.skippedExtensions[].key] | join(", ")' "$FACTS_FILE")
        content="${content}
⚠️ ${skipped_count} extension(s) non vérifiée(s) : ${skipped_keys}"
    fi
fi

if [ "$status" != "success" ] && [ -n "${RUN_URL:-}" ]; then
    content="${content}

<${RUN_URL}>"
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

# L'échec de la notification (429, réseau) reste un warning, pas le verdict du job.
jq -n --arg content "$content" '{content: $content}' \
    | curl -sS --fail-with-body --retry 3 --retry-delay 2 \
        -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL" >/dev/null \
    || echo "::warning::notification Discord échouée (le run lui-même n'est pas affecté)"
