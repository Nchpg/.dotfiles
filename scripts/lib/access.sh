# shellcheck shell=bash
# Fichiers d'accès que le dashboard écrit par commit (sites, appareils VPN, comptes Authelia, clés
# SSH) : la génération active en garde une copie (/etc/dotfiles/access, cf.
# modules/system/access-review). Avant d'activer, ce qui change s'affiche en clair, et rien ne passe
# sans un « oui » tapé ici, même avec --yes : un commit poussé à ton insu ne s'active pas en silence.

access_manifest=${DOTS_ACCESS_MANIFEST:-/etc/dotfiles/access.json}

# Empreinte d'une clé publique (comme ssh-keygen -l), sinon son début.
_access_fp() {
    local fp
    if fp=$(ssh-keygen -lf - <<< "$1" 2> /dev/null); then
        awk '{print $2}' <<< "$fp"
    else
        cut -c1-40 <<< "$1"
    fi
}

# Résumé d'un fichier, de la version active ($2) à celle du dépôt ($3).
_access_summary() {
    local kind=$1 old=$2 new=$3
    case "$kind" in
        vpn)
            jq -rn --slurpfile o "$old" --slurpfile n "$new" '
                def svc: (.services // []) | if . == [] then "aucun" else join(", ") end;
                $o[0] as $o | $n[0] as $n
                | ((($n | keys) - ($o | keys))[] as $k | "  + appareil \($k) (\($n[$k].address)), services : \($n[$k] | svc)"),
                  ((($o | keys) - ($n | keys))[] as $k | "  - appareil \($k) (\($o[$k].address))"),
                  ((($o | keys) - (($o | keys) - ($n | keys)))[] as $k
                   | (if ($o[$k] | del(.services)) != ($n[$k] | del(.services)) then "  ~ appareil \($k) : clé ou adresse changée" else empty end),
                     (if ($o[$k] | svc) != ($n[$k] | svc) then "  ~ appareil \($k) : services \($o[$k] | svc) → \($n[$k] | svc)" else empty end))'
            ;;
        authelia)
            jq -rn --slurpfile o "$old" --slurpfile n "$new" '
                def svc: (.services // []) | if . == [] then "aucun" else join(", ") end;
                $o[0] as $o | $n[0] as $n
                | ((($o + $n) | keys)[]) as $k
                | ($o[$k] // {}) as $a | ($n[$k] // {}) as $b
                | select(($a | svc) != ($b | svc))
                | "  ~ compte \($k) : services \($a | svc) → \($b | svc)"'
            ;;
        ssh)
            local user line
            while IFS=$'\t' read -r sign user line; do
                echo "  $sign clé de $user : ${line##* } ($(_access_fp "$line"))"
            done < <(jq -rn --slurpfile o "$old" --slurpfile n "$new" '
                $o[0] as $o | $n[0] as $n
                | ((($o + $n) | keys)[]) as $u
                | ((($n[$u] // []) - ($o[$u] // []))[] | ["+", $u, .]),
                  ((($o[$u] // []) - ($n[$u] // []))[] | ["-", $u, .])
                | @tsv')
            ;;
        apps)
            jq -rn --slurpfile o "$old" --slurpfile n "$new" '
                $o[0] as $o | $n[0] as $n
                | ((($n | keys) - ($o | keys))[] as $k | "  + site \($k)"),
                  ((($o | keys) - ($n | keys))[] as $k | "  - site \($k)")'
            # Sites modifiés : chaque réglage changé, par son chemin (`environments.preview.accounts`).
            jq -rn --slurpfile o "$old" --slurpfile n "$new" '
                def leaves: [paths(type != "object") | select(all(.[]; type == "string"))] as $ps
                    | reduce $ps[] as $p ({}; .[$p | join(".")] = $p);
                def show: if . == null then "(absent)" else tojson end;
                $o[0] as $o | $n[0] as $n
                | ($o | keys)[] as $k | select(($n | has($k)) and $o[$k] != $n[$k])
                | "  ~ site \($k) :",
                  (($o[$k] | leaves) + ($n[$k] | leaves) | to_entries[]
                   | .value as $p | ($o[$k] | getpath($p)) as $a | ($n[$k] | getpath($p)) as $b
                   | select($a != $b) | "      \(.key) : \($a | show) → \($b | show)")'
            ;;
    esac
}

# À lancer depuis la racine du dépôt, juste avant d'activer.
access_review() {
    local kind path active changed=0
    [ -r "$access_manifest" ] || return 0
    while IFS=$'\t' read -r kind path active; do
        [ -f "$path" ] && [ -r "$active" ] || continue
        cmp -s <(jq -S . "$active") <(jq -S . "$path") && continue
        if [ "$changed" = 0 ]; then
            echo
            echo "${WARN}🔐 Changements d'accès par rapport à ce qui tourne :${R}"
        fi
        changed=1
        echo "${B}$path${R}"
        _access_summary "$kind" "$active" "$path"
    done < <(jq -r '.[] | [.kind, .path, .active] | @tsv' "$access_manifest")
    [ "$changed" = 1 ] || return 0
    echo
    if [ ! -t 0 ]; then
        err "Pas de terminal pour confirmer ces changements d'accès : rebuild annulé."
        exit 1
    fi
    if ! confirm "Activer ces changements d'accès ?" no; then
        echo "${ERR}Rebuild annulé : rien n'a été activé.${R}"
        exit 1
    fi
}
