#!/usr/bin/env bash
# Suit la PR btop #1457 (support du driver GPU Intel xe), greffée en override
# dans default.nix tant qu'elle n'est pas mergée. Met à jour pinned.json sur
# le dernier commit de la branche de la PR (hash via `nix flake prefetch`,
# même hash NAR que fetchFromGitHub). Une fois la PR mergée, ne bumpe plus
# rien et rappelle de retirer l'override.
# Lancé par update.sh (commande `update`, ou `rebuild -u`).
set -euo pipefail

# --check : affiche {name, current, latest, url} en JSON sur stdout, sans rien
# télécharger ni modifier. Utilisé par update.sh pour tout lister avant de
# choisir ; le reste des messages part alors sur stderr.
check=0
if [ "${1:-}" = "--check" ]; then
    check=1
    exec 3>&1 1>&2
fi

flake="${MY_FLAKE:-$HOME/.dotfiles}"
dir="$flake/modules/user/tui/btop"
pinned_file="$dir/pinned.json"
pr=1457

echo "🔎 Checking btop PR #$pr (Intel xe GPU support)..."
# Jeton facultatif (GITHUB_TOKEN, exporté par update.sh depuis gh ou par la
# CI) : sans lui l'API GitHub plafonne à 60 requêtes/h par IP, vite atteint
# sur un runner partagé.
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
if ! pr_json=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/aristocratos/btop/pulls/$pr") \
    || ! state=$(printf '%s' "$pr_json" | jq -er '.state // empty'); then
    echo "⚠️ Error: Could not read btop PR #$pr" >&2
    exit 1
fi

# En --check, la PR mergée ou fermée n'est pas une mise à jour : on remonte
# juste une note, affichée par update.sh à côté des modules à jour.
emit_check() {
    local current
    current=$(jq -r '.rev // empty' "$pinned_file" 2>/dev/null || true)
    jq -nc --arg current "${current:0:7}" --arg latest "${2:-${current:0:7}}" \
        --arg url "${3:-}" --arg note "${1:-}" \
        '{name: "btop (PR #1457 · GPU xe)", $current, $latest, $url, $note}' >&3
    exit 0
}

if [ "$(printf '%s' "$pr_json" | jq -r '.merged')" = "true" ]; then
    [ "$check" -eq 1 ] && emit_check "PR mergée : retirer l'override btopXe"
    echo "🎉 PR #$pr mergée : retirer btopXe de modules/user/tui/btop/default.nix"
    echo "   (et xeGpuSupport) dès que nixpkgs embarque une version de btop qui l'inclut."
    exit 0
fi
if [ "$state" != "open" ]; then
    [ "$check" -eq 1 ] && emit_check "PR fermée sans merge : override à réévaluer"
    echo "⚠️ PR #$pr fermée sans merge : override conservé tel quel, à réévaluer." >&2
    exit 0
fi

repo=$(printf '%s' "$pr_json" | jq -er '.head.repo.full_name')
rev=$(printf '%s' "$pr_json" | jq -er '.head.sha')
echo "Latest PR commit: $rev ($repo)"

if [ "$check" -eq 1 ]; then
    current_rev=$(jq -r '.rev // empty' "$pinned_file" 2>/dev/null || true)
    emit_check "" "${rev:0:7}" "https://github.com/$repo/compare/${current_rev}...${rev}"
fi

if [ -f "$pinned_file" ]; then
    current_rev=$(jq -r '.rev // empty' "$pinned_file" 2>/dev/null || echo "")
    if [ "$current_rev" = "$rev" ]; then
        echo "✓ btop PR #$pr is already up to date (${rev:0:7})"
        exit 0
    fi
fi

# Date du commit dans la version : lisible dans le diff de la PR CI, qui
# compare le champ .version des pinned.json.
if ! date=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$repo/commits/$rev" \
    | jq -er '.commit.committer.date[0:10]'); then
    echo "⚠️ Error: Could not read commit date for $rev" >&2
    exit 1
fi

echo "🔎 Fetching + hashing sources for ${rev:0:7}..."
if ! hash=$(nix flake prefetch --json "github:$repo/$rev" 2>/dev/null | jq -er '.hash'); then
    echo "⚠️ Error: Could not retrieve source hash for btop PR #$pr" >&2
    exit 1
fi

cat <<EOT > "$pinned_file"
{
  "version": "pr$pr-$date-${rev:0:7}",
  "rev": "$rev",
  "hash": "$hash"
}
EOT

echo "⬆️ Updated btop PR #$pr to ${rev:0:7} ($date)"
