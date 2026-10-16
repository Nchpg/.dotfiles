# shellcheck shell=bash

# Pas de -maxdepth : il sautait des modules profonds.
fl_module_updaters() {
    find modules -name update.sh -print0 | sort -z
}

# Exclus : les `follows` (tableaux) et `secrets` (son lock ne bouge que par commit explicite).
fl_bumpable_inputs() {
    jq -r '.nodes.root.inputs | to_entries[]
        | select((.value | type == "string") and .key != "secrets") | .key' "$1" | sort
}

# Séparateur \x1f et non tabulation : `read` fusionne les tabulations consécutives.
fl_input_fields() {
    jq -r --arg n "$2" '
        .nodes[.nodes.root.inputs[$n]] as $node
        | [ $node.original.type,
            ($node.original | '"$FL_OWNER_REPO_JQ"'),
            ($node.original.ref // ""),
            ($node.original.url // ""),
            ($node.locked.rev // ""),
            ($node.locked.lastModified // 0 | strftime("%d/%m")) ]
        | join("\u001f")' "$1"
}

# type=github, ou URL d'un type=git (claude-code-nix).
FL_OWNER_REPO_JQ='if .type == "github" then "\(.owner)/\(.repo)"
    elif .type == "git" then ((.url // "") | capture("^https://github\\.com/(?<o>[^/]+)/(?<r>[^/.]+)(\\.git)?/?$") | "\(.o)/\(.r)") // ""
    else "" end'
fl_owner_repo() {
    jq -r "$FL_OWNER_REPO_JQ"
}

fl_commit_count() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}" auth=()
    [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
    curl -fsSL --max-time 10 "${auth[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$1/compare/$2...$3?per_page=1" 2>/dev/null \
        | jq -er '.ahead_by'
}
