#!/usr/bin/env bash
# Usage: gather-update-facts.sh [skipped-extensions.json] ; nécessite GH_TOKEN (rate-limit anonyme trop bas).
set -euo pipefail

# shellcheck source=scripts/lib/flake-lock.sh
. scripts/lib/flake-lock.sh

at_head() {
    git show "HEAD:$1" 2>/dev/null || true
}

new_lock="flake.lock"
old_lock_content=$(at_head "$new_lock")

root_inputs=$(jq -r '.nodes.root.inputs | keys[]' "$new_lock")

flake_facts="[]"
for name in $root_inputs; do
    old_locked=$(jq -c --arg n "$name" '.nodes[$n].locked // empty' <<<"$old_lock_content")
    new_locked=$(jq -c --arg n "$name" '.nodes[$n].locked // empty' "$new_lock")

    if [ -z "$old_locked" ] || [ "$old_locked" = "$new_locked" ]; then
        continue
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

    slug=$(fl_owner_repo <<<"$new_locked")

    if [ -n "$slug" ] && [ -n "$old_rev" ] && [ -n "$new_rev" ]; then
        compare_url="https://github.com/${slug}/compare/${old_rev}...${new_rev}"
        if ahead_by=$(fl_commit_count "$slug" "$old_rev" "$new_rev"); then
            entry=$(jq --arg compareUrl "$compare_url" --argjson commitCount "$ahead_by" \
                '. + {compareUrl: $compareUrl, commitCount: $commitCount}' <<<"$entry")
        else
            entry=$(jq --arg compareUrl "$compare_url" '. + {compareUrl: $compareUrl}' <<<"$entry")
        fi
    fi

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

# Diff de deux maps JSON {clé: {version, ...}} : clés dont `.version` a changé,
# en {key, oldVersion, newVersion}. `// "nouveau"` : entrée ajoutée.
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
done < <(find modules -name 'pinned.json' -print0 | sort -z)

pinned_facts=$(diff_version_map "$old_pinned_map" "$new_pinned_map" | jq 'map({module: .key, oldVersion, newVersion})')

ext_file="modules/user/editors/vscode/extensions.json"
old_ext_map=$(at_head "$ext_file" | jq -c '. // {}')
new_ext_map=$(jq -c '.' "$ext_file")
vscode_facts=$(diff_version_map "$old_ext_map" "$new_ext_map")

skipped_ext="[]"
if [ -n "${1:-}" ] && [ -s "$1" ]; then
    skipped_ext=$(cat "$1")
fi

jq -n --argjson flakeInputs "$flake_facts" --argjson pinnedUpdates "$pinned_facts" \
    --argjson vscodeExtensions "$vscode_facts" --argjson skippedExtensions "$skipped_ext" \
    '{flakeInputs: $flakeInputs, pinnedUpdates: $pinnedUpdates, vscodeExtensions: $vscodeExtensions, skippedExtensions: $skippedExtensions,
      kernelChanges: [$flakeInputs[] | select(.kernelChanged == true) | {via: .name, from: .oldKernelVersion, to: .newKernelVersion}]}'
