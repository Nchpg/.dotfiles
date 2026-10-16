#!/usr/bin/env bash
set -euo pipefail

here="$(dirname "$0")"
# shellcheck source=scripts/lib/env.sh
. "$here/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"
# shellcheck source=scripts/lib/flake-lock.sh
. "$here/lib/flake-lock.sh"
require_flake update
cd "$flake"

# Un input -> JSON {name, current, latest, url, available} sur stdout.
check_input() {
    local name="$1" type slug ref url rev date remote pattern new
    IFS=$'\x1f' read -r type slug ref url rev date < <(fl_input_fields flake.lock "$name")

    case "$type" in
        github) remote="https://github.com/$slug.git" ;;
        git) remote="$url" ;;
        *) echo "type d'input non géré : $type" >&2; return 1 ;;
    esac
    pattern="${ref:-HEAD}"

    local auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    new=""
    # API GitHub d'abord (~0,4 s contre ~7 s pour un ls-remote sur nixpkgs).
    if [ -n "$slug" ]; then
        new=$(curl -fsSL --max-time 5 "${auth[@]}" -H "Accept: application/vnd.github.sha" \
            "https://api.github.com/repos/$slug/commits/$pattern" 2>/dev/null || true)
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
    if [ -n "$slug" ] && [ "$new" != "$rev" ]; then
        compare="https://github.com/$slug/compare/$rev...$new"
        local ahead
        if ahead=$(fl_commit_count "$slug" "$rev" "$new"); then
            latest="$latest (+$ahead commits)"
        fi
    fi

    jq -nc --arg name "$name" --arg current "${rev:0:7} ($date)" --arg latest "$latest" \
        --arg url "$compare" --argjson available "$([ "$new" != "$rev" ] && echo true || echo false)" \
        '{$name, $current, $latest, $url, $available}'
}

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

interactive=0
if [ "$YES" -eq 0 ] && [ "$CHECK" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    interactive=1
fi
fancy=0
ui_fancy && fancy=1
if [ "$interactive" -eq 1 ] && [ "$fancy" -eq 0 ]; then
    echo "update : gum introuvable — lance la commande \`update\` (ou nix run .#update), qui le fournit." >&2
    exit 1
fi

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

mapfile -d '' -t scripts < <(fl_module_updaters)
m_ids=()
for i in "${!scripts[@]}"; do
    s="${scripts[$i]}"
    matches "$(basename "$(dirname "$s")")" || matches "$s" || continue
    m_ids+=("$i")
    printf 'm\tm%s\t%s\n' "$i" "$flake/$s" >>"$tmp/plan"
done

mapfile -t inputs < <(fl_bumpable_inputs flake.lock)
f_ids=()
for i in "${!inputs[@]}"; do
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

# Les `items` d'un module deviennent des ids à part ; le module passe en « expanded ».
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
    # Pas de `.available // …` : jq traite false comme absent.
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

width=0
for id in "${!NAME[@]}"; do
    [ ${#NAME[$id]} -gt "$width" ] && width=${#NAME[$id]}
done

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

is_default() {
    [[ "$1" == m* ]] || [ "${NAME[$1]}" = claude-code ]
}

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
    # Ctrl+C : abandon (130) ; Échap : rien de coché.
    [ "$rc" -eq 130 ] && return 130
    [ "$rc" -ne 0 ] && return 0
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

failures=0
done_ok=0

# Inputs d'abord : certains update.sh lisent flake.lock.
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

if [ ${#m_sel[@]} -gt 0 ]; then
    echo
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
    rendered=()
    render() {
        local frame="$1" id rc line out="" i=0
        for id in "${m_sel[@]}"; do
            if [ -f "$tmp/${JOB[$id]}.done" ]; then
                rc=$(cat "$tmp/${JOB[$id]}.done")
                if [ "$rc" = 0 ]; then
                    printf -v line '  %s✓%s  %-*s  %s%s%s' "$OK" "$R" "$width" "${NAME[$id]}" "$OK" "${LAT[$id]}" "$R"
                else
                    printf -v line '  %s✗%s  %-*s  %séchec, état précédent conservé%s' "$ERR" "$R" "$width" "${NAME[$id]}" "$ERR" "$R"
                fi
            else
                printf -v line '  %s%s%s  %-*s  %s%s → %s…%s' "$ACC" "$frame" "$R" "$width" "${NAME[$id]}" \
                    "$DIM" "${CUR[$id]}" "${LAT[$id]}" "$R"
            fi
            if [ ! -t 1 ]; then
                out+="$line"$'\n'
            elif [ "${rendered[$i]-}" = "$line" ]; then
                out+=$'\033[1B'
            else
                out+="$line"$'\033[K\n'
            fi
            rendered[i]="$line"
            i=$((i + 1))
        done
        printf '%s' "$out"
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
    for job in "${jobs_order[@]}"; do
        [ "$(cat "$tmp/$job.done")" = 0 ] && continue
        printf '\n  %s%s :%s\n' "$ERR" "${NAME[$job]}" "$R"
        grep -v '^\s*$' "$tmp/$job.log" | tail -n 5 | sed 's/^/     /'
    done
fi

echo
msg="$done_ok mis à jour"
[ "$failures" -gt 0 ] && msg="$msg, ${ERR}$failures en échec${R}"
printf '%s%s%s\n' "$B" "$msg" "$R"
if [ -z "${UPDATE_FROM_REBUILD:-}" ] && [ "$done_ok" -gt 0 ]; then
    printf '%s→ git diff pour relire, puis rebuild pour appliquer.%s\n' "$DIM" "$R"
fi
exit 0
