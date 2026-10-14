#!/usr/bin/env bash
# Envoie un message Discord (via webhook) résumant le run du workflow
# weekly-update : ping l'utilisateur (notif garantie), succès/échec, alerte
# noyau, puis lien de la PR et sa description en dessous (si une PR a été
# créée). Volontairement minimal : en succès, seulement le lien PR (avec
# preview Discord désactivée via <>) pour éviter le bruit des embeds ; le
# lien vers le run GitHub Actions n'apparaît que si le run a échoué (pour
# aller droit aux logs).
#
# Toute la config passe par variables d'environnement (pas d'arguments
# positionnels) :
#   DISCORD_WEBHOOK_URL  requis
#   DISCORD_USER_ID       requis (ping l'utilisateur, sinon pas de notif fiable)
#   STATUS                requis : success|failure|cancelled
#   PR_URL                 optionnel : lien de la PR créée
#   PR_BODY_FILE           optionnel : fichier markdown de la description de la PR
#   FACTS_FILE             optionnel : facts.json (pour l'alerte noyau)
#   RUN_URL                optionnel : lien du run Actions (affiché hors succès)
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

# -s et pas -f : si le step « rassembler les faits » a échoué, la redirection
# a déjà créé un facts.json VIDE, que `-f` laissait passer. Et les deux jq
# ci-dessous sont des affectations : sur un JSON partiel, `set -e` tuerait le
# script — donc justement l'alerte Discord d'échec, au moment où elle sert.
if [ -n "${FACTS_FILE:-}" ] && [ -s "$FACTS_FILE" ]; then
    kernel_count=$(jq '.kernelChanges // [] | length' "$FACTS_FILE" 2>/dev/null || echo 0)
    if [ "$kernel_count" -gt 0 ]; then
        kernel_line=$(jq -r '.kernelChanges[] | "noyau: \(.from) → \(.to)"' "$FACTS_FILE")
        content="${content}
⚠️ ${kernel_line}"
    fi

    # Extensions non vérifiées : sans ça, un run où RIEN n'a bougé mais où des
    # extensions ont été ignorées envoie un « ✅ success » nu, alors qu'on ne
    # sait justement pas si ces extensions étaient à jour. Pas de PR dans ce
    # cas, donc Discord est le seul canal qui reste.
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

# --retry : un 429 (rate-limit Discord) ou un hoquet réseau faisait sortir
# curl en non-zéro sous `set -e`, donc échouer un run par ailleurs réussi —
# PR créée comprise. La notification est le dernier maillon : son échec doit
# rester un warning, pas le verdict du job.
jq -n --arg content "$content" '{content: $content}' \
    | curl -sS --fail-with-body --retry 3 --retry-delay 2 \
        -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL" >/dev/null \
    || echo "::warning::notification Discord échouée (le run lui-même n'est pas affecté)"
