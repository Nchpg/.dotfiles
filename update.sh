#!/usr/bin/env bash

# Mises à jour des dépendances épinglées, sans rebuild. Lançable de n'importe
# où via la commande `update` (cf. modules/system/commands/update) ; `rebuild
# -u` l'appelle avant de reconstruire.
#
# Deux catégories, présentées à part :
#   - les modules épinglés : tout dossier de modules/ qui contient un
#     `update.sh` (auto-découverts, comme côté CI) ;
#   - les inputs du flake (flake.lock), sauf `secrets`, que `rebuild` et la
#     commande `secrets` gèrent déjà à part.
#
# Déroulé, pensé pour ne jamais attendre entre deux questions :
#   1. vérification de TOUT en parallèle, sans rien télécharger (`update.sh
#      --check` côté modules, `git ls-remote` côté inputs) ;
#   2. récapitulatif, puis un seul choix par catégorie (liste à cocher gum) ;
#   3. application : inputs d'abord (`nix flake update`, d'un bloc), puis les
#      modules en parallèle avec un statut par ligne. Un échec reste local à
#      son module, l'état précédent est conservé.
#
# Options :
#   -y, --yes    : pas de question, applique la sélection par défaut (tous les
#                  modules + claude-code, comme l'ancien `rebuild -u -y`)
#   -c, --check  : liste seulement, ne modifie rien
#   NOM...       : restreint aux modules / inputs dont le nom contient NOM
set -euo pipefail

cd "$(dirname "$0")"
flake="$PWD"

# ── Couleurs ─────────────────────────────────────────────────────────────────
# Fournies par la commande `update` (palette Stylix) ; valeurs par défaut sinon
# (appel direct du script).
C_ACCENT="${UPDATE_COLOR_ACCENT:-#7aa2f7}"
C_OK="${UPDATE_COLOR_OK:-#9ece6a}"
C_WARN="${UPDATE_COLOR_WARN:-#e0af68}"
C_ERR="${UPDATE_COLOR_ERR:-#f7768e}"
C_DIM="${UPDATE_COLOR_DIM:-#565f89}"
C_TEXT="${UPDATE_COLOR_TEXT:-#c0caf5}"
export GUM_CHOOSE_CURSOR_FOREGROUND="$C_ACCENT"
export GUM_CHOOSE_SELECTED_FOREGROUND="$C_OK"
export GUM_CHOOSE_HEADER_FOREGROUND="$C_ACCENT"
export GUM_CHOOSE_ITEM_FOREGROUND="$C_TEXT"
export GUM_SPIN_SPINNER_FOREGROUND="$C_ACCENT"

# Hex -> séquence ANSI truecolor.
fg() {
    local h="${1#\#}"
    printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}
# Couleurs seulement vers un terminal (pas dans un pipe ou un log).
if [ -t 1 ]; then
    R=$'\033[0m'
    B=$'\033[1m'
    OK="$(fg "$C_OK")" WARN="$(fg "$C_WARN")" ERR="$(fg "$C_ERR")"
    DIM="$(fg "$C_DIM")" ACC="$(fg "$C_ACCENT")" TXT="$(fg "$C_TEXT")"
else
    R="" B="" OK="" WARN="" ERR="" DIM="" ACC="" TXT=""
fi

# Lien cliquable (OSC 8, kitty & co ; ignoré ailleurs).
link() {
    if [ -n "$2" ] && [ -t 1 ]; then
        # shellcheck disable=SC1003 # ESC \ (fin de séquence OSC), pas un échappement de quote
        printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$2" "$1"
    else
        printf '%s' "$1"
    fi
}

# ── Vérifications (appelé par le script lui-même, en parallèle) ─────────────
# Un input -> JSON {name, current, latest, url, available} sur stdout.
check_input() {
    local name="$1" node type owner repo ref url rev date remote pattern new
    node=$(jq -r --arg n "$name" '.nodes.root.inputs[$n]' flake.lock)
    type=$(jq -r --arg n "$node" '.nodes[$n].original.type' flake.lock)
    owner=$(jq -r --arg n "$node" '.nodes[$n].original.owner // empty' flake.lock)
    repo=$(jq -r --arg n "$node" '.nodes[$n].original.repo // empty' flake.lock)
    ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // empty' flake.lock)
    url=$(jq -r --arg n "$node" '.nodes[$n].original.url // empty' flake.lock)
    rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' flake.lock)
    date=$(jq -r --arg n "$node" '.nodes[$n].locked.lastModified // 0 | strftime("%d/%m")' flake.lock)

    case "$type" in
        github) remote="https://github.com/$owner/$repo.git" ;;
        git) remote="$url" ;;
        *) echo "type d'input non géré : $type" >&2; return 1 ;;
    esac
    pattern="${ref:-HEAD}"

    local auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    new=""
    # API GitHub d'abord : ~0,4 s, contre ~7 s pour un ls-remote sur nixpkgs
    # (des dizaines de milliers de refs). ls-remote en secours (limite de
    # l'API atteinte, dépôt non GitHub), sans invite de mot de passe pour un
    # dépôt privé : échec net à la place.
    if [ "$type" = github ]; then
        new=$(curl -fsSL --max-time 5 "${auth[@]}" -H "Accept: application/vnd.github.sha" \
            "https://api.github.com/repos/$owner/$repo/commits/$pattern" 2>/dev/null || true)
        [[ "$new" =~ ^[0-9a-f]{40}$ ]] || new=""
    fi
    if [ -z "$new" ]; then
        new=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$remote" "$pattern" 2>/dev/null | head -n 1 | cut -f1)
    fi
    if [ -z "$new" ]; then
        echo "git ls-remote a échoué ($remote $pattern)" >&2
        return 1
    fi

    local latest="${new:0:7}" compare=""
    if [ "$type" = github ] && [ "$new" != "$rev" ]; then
        compare="https://github.com/$owner/$repo/compare/$rev...$new"
        # Nombre de commits d'écart, au mieux (API GitHub limitée sans jeton).
        # per_page=1 : seul le compteur sert, pas la liste des commits.
        local ahead
        if ahead=$(curl -fsSL --max-time 5 "${auth[@]}" \
            "https://api.github.com/repos/$owner/$repo/compare/$rev...$new?per_page=1" 2>/dev/null \
            | jq -er '.ahead_by'); then
            latest="$latest (+$ahead commits)"
        fi
    fi

    jq -nc --arg name "$name" --arg current "${rev:0:7} ($date)" --arg latest "$latest" \
        --arg url "$compare" --argjson available "$([ "$new" != "$rev" ] && echo true || echo false)" \
        '{$name, $current, $latest, $url, $available}'
}

# Lance toutes les vérifications du plan en parallèle et attend la fin.
# Chaque job écrit <id>.json (stdout) et <id>.err, puis <id>.rc.
run_checks() {
    local tmp="$1" kind id target
    while IFS=$'\t' read -r kind id target; do
        (
            set +e
            if [ "$kind" = m ]; then
                MY_FLAKE="$flake" "$target" --check >"$tmp/$id.json" 2>"$tmp/$id.err"
            else
                check_input "$target" >"$tmp/$id.json" 2>"$tmp/$id.err"
            fi
            echo $? >"$tmp/$id.rc"
        ) &
    done <"$tmp/plan"
    wait
}

if [ "${1:-}" = "__checks" ]; then
    run_checks "$2"
    exit 0
fi

# ── Arguments ────────────────────────────────────────────────────────────────
YES=0
CHECK=0
filters=()
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) YES=1; shift ;;
        -c|--check) CHECK=1; shift ;;
        -h|--help)
            echo "usage: update [-y|--yes] [-c|--check] [NOM...]"
            echo "  sans option : vérifie tout, puis demande quoi mettre à jour"
            echo "  -y : applique la sélection par défaut (modules + claude-code) sans question"
            echo "  -c : liste les mises à jour disponibles, ne modifie rien"
            echo "  NOM : restreint aux modules / inputs dont le nom contient NOM"
            exit 0 ;;
        -*) echo "update : option inconnue : $1" >&2; exit 1 ;;
        *) filters+=("$1"); shift ;;
    esac
done

# Interactif seulement sur un vrai terminal ; sinon (pipe, CI) comme --yes.
interactive=0
if [ "$YES" -eq 0 ] && [ "$CHECK" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    interactive=1
fi
fancy=0
if [ -t 1 ] && command -v gum >/dev/null 2>&1; then
    fancy=1
fi
if [ "$interactive" -eq 1 ] && [ "$fancy" -eq 0 ]; then
    echo "update : gum introuvable (fourni par la commande \`update\` après un rebuild)." >&2
    exit 1
fi

# Jeton GitHub : relève la limite de l'API (60 requêtes/h sans), lu par les
# update.sh qui interrogent GitHub. Repris de gh s'il est connecté.
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
[ -n "${GITHUB_TOKEN:-}" ] && export GITHUB_TOKEN

matches() {
    [ ${#filters[@]} -eq 0 ] && return 0
    local f
    for f in "${filters[@]}"; do
        [[ "${1,,}" == *"${f,,}"* ]] && return 0
    done
    return 1
}

tmp=$(mktemp -d)
# shellcheck disable=SC2329 # appelée par le trap
cleanup() {
    [ -t 1 ] && printf '\033[?25h'
    rm -rf "$tmp"
}
trap cleanup EXIT

# ── Plan : modules + inputs ─────────────────────────────────────────────────
# Même découverte que la CI : pas de -maxdepth (cf. rebuild.sh pour l'historique).
mapfile -d '' -t scripts < <(find modules -name update.sh -print0 | sort -z)
m_ids=()
for i in "${!scripts[@]}"; do
    s="${scripts[$i]}"
    matches "$(basename "$(dirname "$s")")" || matches "$s" || continue
    m_ids+=("$i")
    printf 'm\tm%s\t%s\n' "$i" "$flake/$s" >>"$tmp/plan"
done

# `follows` (tableaux) exclus : ils suivent un autre input, rien à bumper.
mapfile -t inputs < <(jq -r '.nodes.root.inputs | to_entries[]
    | select(.value | type == "string") | .key' flake.lock | sort)
f_ids=()
for i in "${!inputs[@]}"; do
    [ "${inputs[$i]}" = secrets ] && continue
    matches "${inputs[$i]}" || continue
    f_ids+=("$i")
    printf 'f\tf%s\t%s\n' "$i" "${inputs[$i]}" >>"$tmp/plan"
done

if [ ! -s "$tmp/plan" ]; then
    echo "update : rien ne correspond à : ${filters[*]}" >&2
    exit 1
fi

total=$(wc -l <"$tmp/plan")
plural=""
[ "$total" -gt 1 ] && plural="s"
if [ "$fancy" -eq 1 ]; then
    gum spin --spinner dot --title " Vérification de $total dépendance$plural…" -- "$0" __checks "$tmp"
else
    echo "Vérification de $total dépendance$plural…"
    run_checks "$tmp"
fi

# ── Lecture des résultats ───────────────────────────────────────────────────
# Par id : name, current, latest, url, état (available | uptodate | error |
# expanded). Un module peut détailler des sous-éléments (`items`, ex. une
# ligne par extension VS Code) : chacun devient alors un id proposé à part
# (<id>.<n>, PARENT et KEY renseignés), le module lui-même passe en
# « expanded » et n'est plus listé que pour ses notes.
declare -A NAME CUR LAT URL STATE NOTE SUMMARY ERRMSG PARENT KEY CHILDREN
read_result() {
    local id="$1" fallback="$2" json
    NAME[$id]="$fallback"
    if [ "$(cat "$tmp/$id.rc" 2>/dev/null || echo 1)" != 0 ] || ! json=$(jq -ce . "$tmp/$id.json" 2>/dev/null); then
        STATE[$id]=error
        ERRMSG[$id]=$(grep -v '^\s*$' "$tmp/$id.err" 2>/dev/null | tail -n 1 || true)
        return
    fi
    NAME[$id]=$(jq -r --arg f "$fallback" '.name // $f' <<<"$json")
    CUR[$id]=$(jq -r '.current // ""' <<<"$json")
    LAT[$id]=$(jq -r '.latest // ""' <<<"$json")
    URL[$id]=$(jq -r '.url // ""' <<<"$json")
    NOTE[$id]=$(jq -r '.note // ""' <<<"$json")
    SUMMARY[$id]=$(jq -r '.summary // ""' <<<"$json")
    # Pas de `.available // …` : jq traite false comme absent et retomberait
    # sur la comparaison des libellés.
    if [ "$(jq -r 'if has("available") then .available else .current != .latest end' <<<"$json")" = true ]; then
        STATE[$id]=available
    else
        STATE[$id]=uptodate
    fi

    local n k cid
    n=$(jq -r '.items // [] | length' <<<"$json")
    [ "$n" -gt 0 ] || return 0
    STATE[$id]=expanded
    CHILDREN[$id]=""
    for ((k = 0; k < n; k++)); do
        cid="$id.$k"
        NAME[$cid]=$(jq -r --argjson k "$k" '.items[$k].name' <<<"$json")
        CUR[$cid]=$(jq -r --argjson k "$k" '.items[$k].current // ""' <<<"$json")
        LAT[$cid]=$(jq -r --argjson k "$k" '.items[$k].latest // ""' <<<"$json")
        URL[$cid]=$(jq -r --argjson k "$k" '.items[$k].url // ""' <<<"$json")
        KEY[$cid]=$(jq -r --argjson k "$k" '.items[$k].key' <<<"$json")
        PARENT[$cid]="$id"
        STATE[$cid]=available
        CHILDREN[$id]+="$cid "
    done
}
for i in "${m_ids[@]}"; do read_result "m$i" "$(basename "$(dirname "${scripts[$i]}")")"; done
for i in "${f_ids[@]}"; do read_result "f$i" "${inputs[$i]}"; done

# ── Récapitulatif ───────────────────────────────────────────────────────────
width=0
for id in "${!NAME[@]}"; do
    [ ${#NAME[$id]} -gt "$width" ] && width=${#NAME[$id]}
done

# Ligne d'un élément à mettre à jour (sans couleur : sert aussi de libellé gum).
label() {
    printf "%-${width}s  %s → %s" "${NAME[$1]}" "${CUR[$1]}" "${LAT[$1]}"
}

section() {
    local title="$1"; shift
    local ids=("$@") id avail=() upto=() errs=() notes=()
    for id in "${ids[@]}"; do
        case "${STATE[$id]}" in
            available) avail+=("$id") ;;
            uptodate) upto+=("${NAME[$id]}") ;;
            error) errs+=("$id") ;;
        esac
        [ -n "${NOTE[$id]:-}" ] && notes+=("$id")
    done

    echo
    if [ "$fancy" -eq 1 ]; then
        gum style --bold --foreground "$C_ACCENT" --border rounded --border-foreground "$C_DIM" \
            --padding "0 1" "$title"
    else
        echo "== $title"
    fi
    for id in "${avail[@]}"; do
        printf '  %s⬆%s  %s%s%s  %s%s%s → %s%s%s\n' "$ACC" "$R" "$B$TXT" \
            "$(link "$(printf "%-${width}s" "${NAME[$id]}")" "${URL[$id]}")" "$R" \
            "$DIM" "${CUR[$id]}" "$R" "$OK" "${LAT[$id]}" "$R"
        [ -n "${SUMMARY[$id]:-}" ] && printf '     %s%s%s\n' "$DIM" "${SUMMARY[$id]}" "$R"
    done
    for id in "${notes[@]}"; do
        printf '  %sℹ%s  %s : %s%s%s\n' "$WARN" "$R" "${NAME[$id]}" "$WARN" "${NOTE[$id]}" "$R"
    done
    for id in "${errs[@]}"; do
        printf '  %s✗%s  %s : %s%s%s\n' "$ERR" "$R" "${NAME[$id]}" "$ERR" \
            "${ERRMSG[$id]:-vérification impossible}" "$R"
    done
    if [ ${#upto[@]} -gt 0 ]; then
        local joined
        joined=$(printf '%s, ' "${upto[@]}")
        printf '  %s✓  à jour : %s%s\n' "$DIM" "${joined%, }" "$R"
    fi
}

ids_of() {
    local prefix="$1"; shift
    local i
    for i in "$@"; do echo "$prefix$i"; done
}
# Modules, avec leurs sous-éléments juste après eux.
m_all=()
for id in $(ids_of m "${m_ids[@]}"); do
    m_all+=("$id")
    # shellcheck disable=SC2206 # liste d'ids sans espace, découpage voulu
    [ -n "${CHILDREN[$id]:-}" ] && m_all+=(${CHILDREN[$id]})
done
mapfile -t f_all < <(ids_of f "${f_ids[@]}")
[ ${#m_all[@]} -gt 0 ] && section "📦  Modules épinglés (update.sh)" "${m_all[@]}"
[ ${#f_all[@]} -gt 0 ] && section "❄   Inputs du flake (flake.lock)" "${f_all[@]}"
echo

m_avail=()
for id in "${m_all[@]}"; do [ "${STATE[$id]}" = available ] && m_avail+=("$id"); done
f_avail=()
for id in "${f_all[@]}"; do [ "${STATE[$id]}" = available ] && f_avail+=("$id"); done

if [ ${#m_avail[@]} -eq 0 ] && [ ${#f_avail[@]} -eq 0 ]; then
    printf '%s✓ Tout est à jour.%s\n' "$OK" "$R"
    exit 0
fi
[ "$CHECK" -eq 1 ] && exit 0

# ── Choix ────────────────────────────────────────────────────────────────────
# Par défaut : tous les modules, et parmi les inputs seulement claude-code
# (comportement historique de `rebuild -u`) ; nixpkgs & co se choisissent.
is_default() {
    [[ "$1" == m* ]] || [ "${NAME[$1]}" = claude-code ]
}

# choose <titre> <ids...> : affiche la liste à cocher, imprime les ids retenus.
choose() {
    local header="$1"; shift
    local id labels=() preselected=() picked rc
    declare -A by_label
    for id in "$@"; do
        local l
        l=$(label "$id")
        labels+=("$l")
        by_label["$l"]="$id"
        is_default "$id" && preselected+=("$l")
    done
    local sel
    sel=$(IFS=,; echo "${preselected[*]}")
    set +e
    picked=$(gum choose --no-limit --height 15 \
        --header "$header" --cursor-prefix "› " --selected-prefix "◉ " --unselected-prefix "○ " \
        ${sel:+--selected="$sel"} -- "${labels[@]}")
    rc=$?
    set -e
    # Ctrl+C : on abandonne tout (code 130, relayé par l'appelant : on est
    # dans un sous-shell). Échap : rien de coché dans cette catégorie.
    [ "$rc" -eq 130 ] && return 130
    [ "$rc" -ne 0 ] && return 0
    # Rendus dans l'ordre de la liste, quel que soit l'ordre de cochage.
    declare -A chosen
    while IFS= read -r l; do
        [ -n "$l" ] && chosen["${by_label[$l]}"]=1
    done <<<"$picked"
    for id in "$@"; do
        [ -n "${chosen[$id]:-}" ] && echo "$id"
    done
    return 0
}

m_sel=()
f_sel=()
if [ "$interactive" -eq 1 ]; then
    # gum affiche déjà ses touches (x, ctrl+a, entrée) ; seul Échap mérite
    # d'être rappelé.
    hint="échap : aucun"
    if [ ${#m_avail[@]} -gt 0 ]; then
        out=$(choose "📦 Modules à mettre à jour   ($hint)" "${m_avail[@]}") \
            || { echo "Annulé." >&2; exit 130; }
        [ -n "$out" ] && mapfile -t m_sel <<<"$out"
    fi
    if [ ${#f_avail[@]} -gt 0 ]; then
        out=$(choose "❄  Inputs du flake à mettre à jour   ($hint)" "${f_avail[@]}") \
            || { echo "Annulé." >&2; exit 130; }
        [ -n "$out" ] && mapfile -t f_sel <<<"$out"
    fi
else
    for id in "${m_avail[@]}"; do is_default "$id" && m_sel+=("$id"); done
    for id in "${f_avail[@]}"; do is_default "$id" && f_sel+=("$id"); done
fi

if [ ${#m_sel[@]} -eq 0 ] && [ ${#f_sel[@]} -eq 0 ]; then
    printf '%sRien de sélectionné.%s\n' "$DIM" "$R"
    exit 0
fi

# ── Application ─────────────────────────────────────────────────────────────
failures=0
done_ok=0

# Inputs d'abord, d'un bloc : certains update.sh lisent flake.lock (spotify
# vendore ses dépendances avec le nixpkgs locké), autant qu'ils voient le neuf.
if [ ${#f_sel[@]} -gt 0 ]; then
    names=()
    for id in "${f_sel[@]}"; do names+=("${NAME[$id]}"); done
    echo
    if [ "$fancy" -eq 1 ]; then
        # shellcheck disable=SC2016 # développé par le bash -c, pas ici
        gum spin --spinner dot --title " nix flake update ${names[*]}…" \
            -- bash -c 'log="$1"; shift; nix flake update "$@" >"$log" 2>&1' _ "$tmp/flake.log" "${names[@]}" \
            && rc=0 || rc=$?
    else
        nix flake update "${names[@]}" >"$tmp/flake.log" 2>&1 && rc=0 || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        for id in "${f_sel[@]}"; do
            printf '  %s✓%s  %-*s  %s%s%s\n' "$OK" "$R" "$width" "${NAME[$id]}" "$OK" "${LAT[$id]}" "$R"
        done
        done_ok=$((done_ok + ${#f_sel[@]}))
    else
        printf '  %s✗  nix flake update a échoué (flake.lock inchangé) :%s\n' "$ERR" "$R"
        tail -n 5 "$tmp/flake.log" | sed 's/^/     /'
        failures=$((failures + ${#f_sel[@]}))
    fi
fi

# Modules en parallèle, un statut par ligne rafraîchi sur place.
if [ ${#m_sel[@]} -gt 0 ]; then
    echo
    # Un job par script : les sous-éléments cochés d'un même module partent
    # ensemble, via `--only KEY...`.
    declare -A JOB ONLY
    jobs_order=()
    for id in "${m_sel[@]}"; do
        job="${PARENT[$id]:-$id}"
        JOB[$id]="$job"
        if [ -z "${ONLY[$job]+set}" ]; then
            ONLY[$job]=""
            jobs_order+=("$job")
        fi
        [ -n "${KEY[$id]:-}" ] && ONLY[$job]+="${KEY[$id]} "
    done
    for job in "${jobs_order[@]}"; do
        script="${scripts[${job#m}]}"
        args=()
        # shellcheck disable=SC2206 # clés sans espace, découpage voulu
        [ -n "${ONLY[$job]}" ] && args=(--only ${ONLY[$job]})
        (
            set +e
            MY_FLAKE="$flake" "$flake/$script" "${args[@]}" >"$tmp/$job.log" 2>&1
            echo $? >"$tmp/$job.done"
        ) &
    done

    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    n=${#m_sel[@]}
    render() {
        local frame="$1" id rc
        for id in "${m_sel[@]}"; do
            printf '\033[2K'
            if [ -f "$tmp/${JOB[$id]}.done" ]; then
                rc=$(cat "$tmp/${JOB[$id]}.done")
                if [ "$rc" = 0 ]; then
                    printf '  %s✓%s  %-*s  %s%s%s\n' "$OK" "$R" "$width" "${NAME[$id]}" "$OK" "${LAT[$id]}" "$R"
                else
                    printf '  %s✗%s  %-*s  %séchec, état précédent conservé%s\n' "$ERR" "$R" "$width" "${NAME[$id]}" "$ERR" "$R"
                fi
            else
                printf '  %s%s%s  %-*s  %s%s → %s…%s\n' "$ACC" "$frame" "$R" "$width" "${NAME[$id]}" \
                    "$DIM" "${CUR[$id]}" "${LAT[$id]}" "$R"
            fi
        done
    }
    all_done() {
        local job
        for job in "${jobs_order[@]}"; do [ -f "$tmp/$job.done" ] || return 1; done
    }

    if [ -t 1 ]; then
        printf '\033[?25l'
        k=0
        render "${frames[0]}"
        until all_done; do
            sleep 0.1
            k=$(((k + 1) % ${#frames[@]}))
            printf '\033[%dA' "$n"
            render "${frames[$k]}"
        done
        printf '\033[%dA' "$n"
        render ""
        printf '\033[?25h'
    else
        wait
        render ""
    fi
    wait

    for id in "${m_sel[@]}"; do
        if [ "$(cat "$tmp/${JOB[$id]}.done")" = 0 ]; then
            done_ok=$((done_ok + 1))
        else
            failures=$((failures + 1))
        fi
    done
    # Log des échecs, une fois par job (pas par sous-élément).
    for job in "${jobs_order[@]}"; do
        [ "$(cat "$tmp/$job.done")" = 0 ] && continue
        printf '\n  %s%s :%s\n' "$ERR" "${NAME[$job]}" "$R"
        grep -v '^\s*$' "$tmp/$job.log" | tail -n 5 | sed 's/^/     /'
    done
fi

# ── Bilan ────────────────────────────────────────────────────────────────────
echo
msg="$done_ok mis à jour"
[ "$failures" -gt 0 ] && msg="$msg, ${ERR}$failures en échec${R}"
printf '%s%s%s\n' "$B" "$msg" "$R"
if [ -z "${UPDATE_FROM_REBUILD:-}" ] && [ "$done_ok" -gt 0 ]; then
    printf '%s→ git diff pour relire, puis rebuild pour appliquer.%s\n' "$DIM" "$R"
fi
exit 0
