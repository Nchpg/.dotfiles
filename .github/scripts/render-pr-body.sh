#!/usr/bin/env bash
# Construit le corps Markdown de la PR à partir des faits de
# gather-update-facts.sh. 100% déterministe : pour chaque input flake, le
# nombre de commits (si connu) et un lien vers la comparaison GitHub — aucun
# contenu de commit n'est résumé ni interprété, donc aucun risque d'invention
# et aucune limite de tokens à surveiller.
#
# Usage: render-pr-body.sh <facts.json>
set -euo pipefail

facts_file="$1"

flake_count=$(jq '.flakeInputs | length' "$facts_file")
ext_count=$(jq '.vscodeExtensions | length' "$facts_file")

if [ "$flake_count" -gt 0 ]; then
    echo "## Inputs flake"
    echo
    jq -r '.flakeInputs[] |
      "- **\(.name)** : " +
      (if .commitCount != null then "\(.commitCount) commit(s)" else "révision changée" end) +
      (if .compareUrl then " — [comparer sur GitHub](\(.compareUrl))" else "" end)
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
