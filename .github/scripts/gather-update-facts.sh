#!/usr/bin/env bash
# Compare l'état AVANT (HEAD, avant tout bump) et APRÈS (working tree, une
# fois flake.lock / pinned.json / extensions.json mis à jour) et produit un
# JSON de FAITS : pour chaque input flake racine dont le lock a changé, date
# + rev avant/après, nombre de commits entre les deux (si c'est un dépôt
# GitHub) et lien de comparaison. Idem pour chaque module à `pinned.json`
# (auto-découvert, cf. update.yml) et pour les extensions VS Code dont la
# version a bougé. Si nixpkgs-stable change, compare aussi la version du
# noyau (linuxPackages_latest) avant/après.
#
# Tout est comparé via `git show HEAD:<path>` vs le fichier courant : comme
# flake.lock, pinned.json et extensions.json sont tous trackés, pas besoin de
# copier un "avant" à part avant de lancer les bumps.
#
# Volontairement minimal : pas de contenu de commit récupéré ni interprété
# (juste un compte + un lien) — consommé par render-pr-body.sh, qui construit
# le corps de la PR de façon 100% déterministe (aucun LLM).
#
# Usage: gather-update-facts.sh [skipped-extensions.json]
# Nécessite GH_TOKEN dans l'environnement (auth API GitHub, sinon rate-limit
# anonyme trop bas pour ~8 inputs).
set -euo pipefail

# Contenu d'un fichier à HEAD, ou vide s'il n'existait pas encore.
at_head() {
    git show "HEAD:$1" 2>/dev/null || true
}

new_lock="flake.lock"
old_lock_content=$(at_head "$new_lock")

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
    old_locked=$(jq -c --arg n "$name" '.nodes[$n].locked // empty' <<<"$old_lock_content")
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

# Diff générique entre deux maps JSON {clé: {version, ...}} : liste des clés
# dont `.version` a changé, en {key, oldVersion, newVersion}. Partagé par les
# pinned.json (1 fichier par module, assemblés en map ci-dessous) et
# extensions.json (déjà une map, 1 clé par extension) — même notion de
# "version épinglée qui a bougé", juste un stockage différent en amont (un
# fichier par entité vs une seule map à plusieurs entités, chacun adapté à son
# usage : pas de raison de forcer les deux dans le même format de fichier).
# `// "nouveau"` : pour une entrée AJOUTÉE, $old[clé] vaut null et la PR
# afficherait sinon littéralement « foo : null → 1.2.3 ».
diff_version_map() {
    local old="$1" new="$2"
    jq -n --argjson old "$old" --argjson new "$new" '
      [ $new | keys[] | select($old[.].version != $new[.].version) | {
          key: .,
          oldVersion: ($old[.].version // "nouveau"),
          newVersion: $new[.].version
        }
      ]'
}

# Modules à pin unique (kimi-code, et tout futur module du même moule) :
# auto-découverts par leur pinned.json, pas de liste en dur ici non plus.
# Assemblés en une map {module: <contenu du pinned.json>} pour être diffés par
# la même fonction que les extensions vscode.
old_pinned_map="{}"
new_pinned_map="{}"
while IFS= read -r -d '' pinned_file; do
    module=$(basename "$(dirname "$pinned_file")")
    old_entry=$(at_head "$pinned_file" | jq -c '. // empty')
    new_entry=$(jq -c '.' "$pinned_file")

    if [ -n "$old_entry" ]; then
        old_pinned_map=$(jq --arg m "$module" --argjson e "$old_entry" '.[$m] = $e' <<<"$old_pinned_map")
    fi
    new_pinned_map=$(jq --arg m "$module" --argjson e "$new_entry" '.[$m] = $e' <<<"$new_pinned_map")
done < <(find modules -maxdepth 4 -name 'pinned.json' -print0 | sort -z)

pinned_facts=$(diff_version_map "$old_pinned_map" "$new_pinned_map" | jq 'map({module: .key, oldVersion, newVersion})')

ext_file="modules/user/vscode/extensions.json"
old_ext_map=$(at_head "$ext_file" | jq -c '. // {}')
new_ext_map=$(jq -c '.' "$ext_file")
vscode_facts=$(diff_version_map "$old_ext_map" "$new_ext_map")

# Argument optionnel : extensions qu'update.sh (vscode) n'a PAS pu vérifier
# (API Marketplace en erreur, téléchargement échoué). Elles ne font pas
# échouer le run, donc sans ça elles ne seraient visibles que dans le log.
skipped_ext="[]"
if [ -n "${1:-}" ] && [ -s "$1" ]; then
    skipped_ext=$(cat "$1")
fi

jq -n --argjson flakeInputs "$flake_facts" --argjson pinnedUpdates "$pinned_facts" \
    --argjson vscodeExtensions "$vscode_facts" --argjson skippedExtensions "$skipped_ext" \
    '{flakeInputs: $flakeInputs, pinnedUpdates: $pinnedUpdates, vscodeExtensions: $vscodeExtensions, skippedExtensions: $skippedExtensions}'
