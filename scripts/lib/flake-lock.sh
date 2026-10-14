# shellcheck shell=bash
# Lecture de flake.lock et des dépendances épinglées, partagée par
# scripts/update.sh (commande `update`, `rebuild -u`) et la CI hebdomadaire
# (.github/workflows/update.yml, .github/scripts/gather-update-facts.sh).
# Les deux doivent voir EXACTEMENT les mêmes listes : un module que l'un
# découvre et pas l'autre se met à jour d'un côté seulement, sans un message.
# Nécessite jq (et curl pour fl_commit_count).

# Les update.sh des modules épinglés, NUL-séparés, triés. Pas de -maxdepth :
# il valait 4 et sautait silencieusement dev/vercel-cli/claude-plugin/update.sh
# (un cran plus profond), dont l'épingle n'a donc jamais été bumpée. Borner la
# profondeur couple la découverte à l'arborescence des modules — un
# déplacement de dossier désactive une mise à jour sans le moindre message.
# À lancer depuis la racine du dépôt.
fl_module_updaters() {
    find modules -name update.sh -print0 | sort -z
}

# Inputs racine à bumper, un par ligne, triés. Exclus :
#   - les `follows` (tableaux) : ils suivent un autre input, rien à bumper ;
#   - `secrets` : son lock ne bouge que par un commit explicite (`secrets
#     sync`), et le jeton de la CI ne voit de toute façon pas le dépôt privé.
fl_bumpable_inputs() {
    jq -r '.nodes.root.inputs | to_entries[]
        | select((.value | type == "string") and .key != "secrets") | .key' "$1" | sort
}

# Un input du lock, en une ligne « type, owner/repo, ref, url, rev, date »
# (champ vide si absent), en UN SEUL jq. Séparateur \x1f et pas une
# tabulation : `read` fusionne les tabulations consécutives (blanc d'IFS),
# donc un champ vide décalerait tous les suivants :
#   IFS=$'\x1f' read -r type slug ref url rev date < <(fl_input_fields flake.lock NOM)
# Le nœud est celui que la racine désigne : Nix renomme un nœud (`foo_2`) quand deux entrées portent le
# même nom. owner/repo aussi pour un type=git pointant sur github.com
# (claude-code), cf. fl_owner_repo.
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

# owner/repo GitHub d'un nœud `original` ou `locked` (JSON sur l'entrée
# standard), vide si ce n'est pas un dépôt GitHub : direct si type=github,
# sinon extrait de l'URL d'un type=git (ex. claude-code-nix, en git+https
# parce que `github:` exige un jeton en CI).
FL_OWNER_REPO_JQ='if .type == "github" then "\(.owner)/\(.repo)"
    elif .type == "git" then ((.url // "") | capture("^https://github\\.com/(?<o>[^/]+)/(?<r>[^/.]+)(\\.git)?/?$") | "\(.o)/\(.r)") // ""
    else "" end'
fl_owner_repo() {
    jq -r "$FL_OWNER_REPO_JQ"
}

# fl_commit_count <owner/repo> <ancien rev> <nouveau rev> : nombre de commits
# d'écart, par l'API GitHub (GITHUB_TOKEN ou GH_TOKEN si posé : 60 requêtes/h
# sans). Échoue (code non nul, rien sur stdout) si l'API ne répond pas.
# per_page=1 : seul le compteur sert, pas la liste des commits.
fl_commit_count() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}" auth=()
    [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
    curl -fsSL --max-time 10 "${auth[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$1/compare/$2...$3?per_page=1" 2>/dev/null \
        | jq -er '.ahead_by'
}
