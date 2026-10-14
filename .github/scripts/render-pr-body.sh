#!/usr/bin/env bash
# Construit le corps Markdown de la PR à partir des faits de
# gather-update-facts.sh. 100% déterministe : pour chaque input flake, dates
# avant/après et nombre de commits (si connu) — aucun contenu de commit n'est
# résumé ni interprété, donc aucun risque d'invention et aucune limite de
# tokens à surveiller. Pas de lien de comparaison (repris tel quel dans la
# notif Discord, qui doit rester minimale).
#
# Usage: render-pr-body.sh <facts.json>
set -euo pipefail

facts_file="$1"

flake_count=$(jq '.flakeInputs | length' "$facts_file")
pinned_count=$(jq '.pinnedUpdates | length' "$facts_file")
ext_count=$(jq '.vscodeExtensions | length' "$facts_file")

if [ "$(jq '.kernelChanges | length' "$facts_file")" -gt 0 ]; then
    echo "## ⚠️ Changement de version du noyau"
    echo
    jq -r '.kernelChanges[] |
      "Le noyau Linux passe de **\(.from)** à **\(.to)** (via \(.via))."
    ' "$facts_file"
    echo
fi

if [ "$flake_count" -gt 0 ]; then
    echo "## Inputs flake"
    echo
    jq -r '.flakeInputs[] |
      "- **\(.name)** : " +
      (if .oldDate != "" and .newDate != "" then "\(.oldDate) → \(.newDate)" else "date inconnue" end) +
      ", " +
      (if .commitCount != null then "\(.commitCount) commit(s)" else "révision changée" end)
    ' "$facts_file"
    echo
fi

if [ "$pinned_count" -gt 0 ]; then
    echo "## Modules épinglés"
    echo
    jq -r '.pinnedUpdates[] |
      "- **\(.module)** : \(.oldVersion) → \(.newVersion)"
    ' "$facts_file"
    echo
fi

if [ "$ext_count" -gt 0 ]; then
    echo "## Extensions VS Code"
    echo
    jq -r '.vscodeExtensions[] |
      "- **\(.key)** : \(.oldVersion) → \(.newVersion)"
    ' "$facts_file"
    echo
fi

# Extensions non vérifiées ce coup-ci : leur version ET leur hash sont restés
# tels quels. Ce n'est pas bloquant, mais ça doit se voir dans la PR — sinon
# l'absence d'une extension de la liste ci-dessus se lit à tort comme « rien
# n'a changé » alors qu'on n'en sait rien.
skipped_count=$(jq '.skippedExtensions // [] | length' "$facts_file")
if [ "$skipped_count" -gt 0 ]; then
    echo "## ⚠️ Extensions non vérifiées"
    echo
    jq -r '.skippedExtensions[] | "- **\(.key)** : \(.reason)"' "$facts_file"
    echo
    echo "Version et hash inchangés pour ces extensions — à revérifier au prochain run."
    echo
fi
