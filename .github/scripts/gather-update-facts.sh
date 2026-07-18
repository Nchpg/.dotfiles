#!/usr/bin/env bash
# Compare un flake.lock + extensions.json AVANT/APRÈS un bump et produit un
# JSON de FAITS : pour chaque input flake racine dont le lock a changé, date
# + rev avant/après, nombre de commits entre les deux (si c'est un dépôt
# GitHub) et lien de comparaison. Idem pour les extensions VS Code dont la
# version a bougé. Si nixpkgs-stable change, compare aussi la version du
# noyau (linuxPackages_latest) avant/après.
#
# Volontairement minimal : pas de contenu de commit récupéré ni interprété
# (juste un compte + un lien) — consommé par render-pr-body.sh, qui construit
# le corps de la PR de façon 100% déterministe (aucun LLM).
#
# Usage: gather-update-facts.sh <old-flake.lock> <new-flake.lock> <old-extensions.json> <new-extensions.json>
# Nécessite GH_TOKEN dans l'environnement (auth API GitHub, sinon rate-limit
# anonyme trop bas pour ~8 inputs).
set -euo pipefail

old_lock="$1"
new_lock="$2"
old_ext="$3"
new_ext="$4"

gh_api() {
    curl -sf -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

# owner/repo d'un node "locked" : direct si type=github, sinon extrait de
# l'URL si c'est un type=git pointant vers github.com (ex. claude-code-nix).
locked_owner_repo() {
    local locked="$1"
    local type owner repo url
    type=$(jq -r '.type // empty' <<<"$locked")
    if [ "$type" = "github" ]; then
        owner=$(jq -r '.owner // empty' <<<"$locked")
        repo=$(jq -r '.repo // empty' <<<"$locked")
    elif [ "$type" = "git" ]; then
        url=$(jq -r '.url // empty' <<<"$locked")
        if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
            owner="${BASH_REMATCH[1]}"
            repo="${BASH_REMATCH[2]}"
        fi
    fi
    jq -n --arg owner "${owner:-}" --arg repo "${repo:-}" '{owner: $owner, repo: $repo}'
}

root_inputs=$(jq -r '.nodes.root.inputs | keys[]' "$new_lock")

flake_facts="[]"
for name in $root_inputs; do
    old_locked=$(jq -c --arg n "$name" '.nodes[$n].locked // empty' "$old_lock")
    new_locked=$(jq -c --arg n "$name" '.nodes[$n].locked // empty' "$new_lock")

    if [ -z "$old_locked" ] || [ "$old_locked" = "$new_locked" ]; then
        continue # input absent avant, ou inchangé
    fi

    old_rev=$(jq -r '.rev // empty' <<<"$old_locked")
    new_rev=$(jq -r '.rev // empty' <<<"$new_locked")
    old_date=$(jq -r '.lastModified // empty' <<<"$old_locked")
    new_date=$(jq -r '.lastModified // empty' <<<"$new_locked")
    old_date=$([ -n "$old_date" ] && date -u -d "@${old_date}" +%Y-%m-%d || echo "")
    new_date=$([ -n "$new_date" ] && date -u -d "@${new_date}" +%Y-%m-%d || echo "")

    entry=$(jq -n --arg name "$name" --arg oldRev "$old_rev" --arg newRev "$new_rev" \
        --arg oldDate "$old_date" --arg newDate "$new_date" \
        '{name: $name, oldRev: $oldRev, newRev: $newRev, oldDate: $oldDate, newDate: $newDate, compareUrl: null, commitCount: null}')

    or=$(locked_owner_repo "$new_locked")
    owner=$(jq -r '.owner' <<<"$or")
    repo=$(jq -r '.repo' <<<"$or")

    if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$old_rev" ] && [ -n "$new_rev" ]; then
        compare_url="https://github.com/${owner}/${repo}/compare/${old_rev}...${new_rev}"
        if compare_json=$(gh_api "https://api.github.com/repos/${owner}/${repo}/compare/${old_rev}...${new_rev}" 2>/dev/null); then
            ahead_by=$(jq -r '.ahead_by // 0' <<<"$compare_json")
            entry=$(jq --arg compareUrl "$compare_url" --argjson commitCount "$ahead_by" \
                '. + {compareUrl: $compareUrl, commitCount: $commitCount}' <<<"$entry")
        else
            entry=$(jq --arg compareUrl "$compare_url" '. + {compareUrl: $compareUrl}' <<<"$entry")
        fi
    fi

    # Alerte changement de version de noyau : nixpkgs-stable fournit
    # linuxPackages_latest (cf. modules/system/boot). On évalue la version du
    # noyau aux deux revs pour distinguer un vrai bump de noyau d'un simple
    # bump de nixpkgs sans impact sur le noyau.
    if [ "$name" = "nixpkgs-stable" ] && [ -n "$old_rev" ] && [ -n "$new_rev" ]; then
        kernel_attr="legacyPackages.x86_64-linux.linuxPackages_latest.kernel.version"
        old_kernel=$(nix eval --raw "github:NixOS/nixpkgs/${old_rev}#${kernel_attr}" 2>/dev/null || echo "")
        new_kernel=$(nix eval --raw "github:NixOS/nixpkgs/${new_rev}#${kernel_attr}" 2>/dev/null || echo "")
        if [ -n "$old_kernel" ] && [ -n "$new_kernel" ]; then
            kernel_changed=$([ "$old_kernel" != "$new_kernel" ] && echo true || echo false)
            entry=$(jq --arg oldKernel "$old_kernel" --arg newKernel "$new_kernel" --argjson kernelChanged "$kernel_changed" \
                '. + {oldKernelVersion: $oldKernel, newKernelVersion: $newKernel, kernelChanged: $kernelChanged}' <<<"$entry")
        fi
    fi

    flake_facts=$(jq --argjson e "$entry" '. + [$e]' <<<"$flake_facts")
done

vscode_facts=$(jq -n --slurpfile old "$old_ext" --slurpfile new "$new_ext" '
  ($old[0]) as $o | ($new[0]) as $n |
  [ $n | keys[] | select($o[.].version != $n[.].version) | {
      key: .,
      oldVersion: $o[.].version,
      newVersion: $n[.].version
    }
  ]
')

# 5e argument optionnel : extensions qu'update-extensions.sh n'a PAS pu
# vérifier (API Marketplace en erreur, téléchargement échoué). Elles ne font
# pas échouer le run, donc sans ça elles ne seraient visibles que dans le log.
skipped_ext="[]"
if [ -n "${5:-}" ] && [ -s "$5" ]; then
    skipped_ext=$(cat "$5")
fi

jq -n --argjson flakeInputs "$flake_facts" --argjson vscodeExtensions "$vscode_facts" \
    --argjson skippedExtensions "$skipped_ext" \
    '{flakeInputs: $flakeInputs, vscodeExtensions: $vscodeExtensions, skippedExtensions: $skippedExtensions}'
