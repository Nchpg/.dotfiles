#!/usr/bin/env bash
# Pas de lien de comparaison (le corps est repris dans Discord).
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

# Rattrapage : d'ordinaire, la CI de l'app épingle par apps.yml (think).
if [ "$(jq '.appImages // [] | length' "$facts_file")" -gt 0 ]; then
    echo "## Images des apps"
    echo
    jq -r '.appImages[] |
      "- **\(.key)** : \(.oldVersion) → \(.newVersion)"
    ' "$facts_file"
    echo
    echo "Tag publié sans épinglage automatique : jeton DOTFILES_DISPATCH_TOKEN absent ou expiré côté app ?"
    echo
fi

skipped_count=$(jq '.skippedExtensions // [] | length' "$facts_file")
if [ "$skipped_count" -gt 0 ]; then
    echo "## ⚠️ Extensions non vérifiées"
    echo
    jq -r '.skippedExtensions[] | "- **\(.key)** : \(.reason)"' "$facts_file"
    echo
    echo "Version et hash inchangés pour ces extensions — à revérifier au prochain run."
    echo
fi
