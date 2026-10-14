#!/usr/bin/env bash
# Recense les contournements temporaires du dépôt et, quand c'est possible,
# dit s'ils ont expiré. Sortie : une section Markdown pour le corps de la PR
# hebdomadaire (rien du tout si aucun marqueur).
#
# Convention : une ligne dont le commentaire COMMENCE par le marqueur, soit
# `#` suivi de EXPIRE, une condition FACULTATIVE entre parenthèses, puis
# deux-points et un texte libre jusqu'au bout de la ligne. L'ancrage en début
# de commentaire est ce qui distingue un vrai marqueur d'une simple mention en
# prose (ce fichier, update.yml...).
#
# Le texte est repris tel quel, et doit tenir sur UNE ligne : ce qui déborde
# sur la ligne suivante est perdu.
#
# Deux conditions sont VÉRIFIÉES, et le verdict apparaît dans la PR :
#
#   # EXPIRE: … https://github.com/owner/repo/pull/123
#       une URL de PR/issue GitHub dans le texte : état interrogé via `gh`.
#       PR mergée / issue fermée = le contournement peut sauter.
#
#   # EXPIRE(option:services.journald.settings): …
#       une option NixOS qui n'existe pas encore dans le nixpkgs épinglé.
#       Le jour où elle APPARAÎT, le contournement peut sauter.
#
# Sans condition, la ligne est simplement listée : un rappel hebdomadaire,
# faute de mieux. S'il contient une URL de PR ou d'issue GitHub,
# son état est interrogé : une PR mergée / une issue fermée signifie que le
# contournement n'a plus lieu d'être, et la ligne est marquée en conséquence.
#
# Pourquoi : ces contournements (override d'un paquet sur une PR amont non
# mergée, option pas encore en stable...) sont des dettes datées que rien ne
# rappelle. Ils pourrissent en silence — on continue de faire tourner un fork
# longtemps après que l'amont a corrigé le problème.
#
# Nécessite `gh` authentifié pour la résolution d'état ; sans lui, les lignes
# sont listées sans verdict (jamais bloquant).
set -euo pipefail

cd "${MY_FLAKE:-$(git rev-parse --show-toplevel)}"

# -I : ignore les binaires. Aucun chemin exclu : l'ancrage du motif suffit à
# ne pas ramasser les mentions en prose, y compris celles de ce fichier.
mapfile -t hits < <(
    git grep -n -I -E '^[[:space:]]*#[[:space:]]*EXPIRE(\([^)]*\))?:' || true
)

[ ${#hits[@]} -eq 0 ] && exit 0

# Conditions `option:` de TOUS les marqueurs, vérifiées en UNE éval du flake
# (~30 s chacune, autant n'en payer qu'une) : objet JSON chemin -> booléen.
# `|| echo {}` : une éval cassée ne doit pas faire tomber la PR, les chemins
# absents de l'objet sortent en « invérifiable ».
opt_paths="$(printf '%s\n' "${hits[@]}" | sed -nE 's/.*EXPIRE\(option:([^)]+)\).*/\1/p' | sort -u)"
opt_state='{}'
if [ -n "$opt_paths" ]; then
    opt_state="$(
        EXPIRE_OPTION_PATHS="$opt_paths" nix eval --impure --json --no-warn-dirty --expr '
          let
            f = builtins.getFlake (toString ./.);
            lib = f.inputs.nixpkgs-stable.lib;
            o = (builtins.head (builtins.attrValues f.nixosConfigurations)).options;
            paths = lib.filter (p: p != "") (lib.splitString "\n" (builtins.getEnv "EXPIRE_OPTION_PATHS"));
          in
          lib.genAttrs paths (p: lib.hasAttrByPath (lib.splitString "." p) o)
        ' 2>/dev/null || echo '{}'
    )"
fi

echo "## Contournements temporaires"
echo

for hit in "${hits[@]}"; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"

    # Garde ce qui suit le marqueur ET sa condition facultative : le premier
    # deux-points de la ligne peut être DANS la parenthèse (option:a.b.c),
    # donc on retire le motif complet plutôt que de couper au premier ':'.
    note="$(echo "$text" | sed -E 's/.*EXPIRE(\([^)]*\))?:[[:space:]]*//')"
    # Un tiret final (note coupée en fin de ligne) ferait doublon avec celui
    # que le verdict ajoute.
    note="$(echo "$note" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]*[-—]$//')"

    verdict=""

    # Condition explicite « (option:<chemin>) » collée au marqueur.
    opt_path="$(echo "$text" | sed -nE 's/.*EXPIRE\(option:([^)]+)\).*/\1/p')"
    if [ -n "$opt_path" ]; then
        exists="$(jq -r --arg p "$opt_path" 'if has($p) then .[$p] else "?" end' <<<"$opt_state")"
        case "$exists" in
        true) verdict=" — ✅ **\`$opt_path\` existe désormais, le contournement peut sauter**" ;;
        false) verdict=" — \`$opt_path\` toujours absent" ;;
        *) verdict=" — état de \`$opt_path\` invérifiable" ;;
        esac
    fi

    url="$(echo "$note" | grep -oE 'https://github\.com/[^ )]+/(pull|issues)/[0-9]+' | head -1 || true)"
    if [ -z "$verdict" ] && [ -n "$url" ] && command -v gh >/dev/null 2>&1; then
        # .../<owner>/<repo>/<kind>/<num>
        num="${url##*/}"
        kind="$(basename "$(dirname "$url")")"
        repo="$(echo "$url" | sed -E 's|https://github\.com/([^/]+/[^/]+)/.*|\1|')"

        if [ "$kind" = "pull" ]; then
            state="$(gh api "repos/$repo/pulls/$num" --jq 'if .merged then "merged" else .state end' 2>/dev/null || echo "?")"
            case "$state" in
            merged) verdict=" — ✅ **PR mergée en amont, le contournement peut sauter**" ;;
            closed) verdict=" — ⚠️ PR fermée sans merge, à réexaminer" ;;
            open) verdict=" — toujours ouverte" ;;
            *) verdict=" — état inconnu" ;;
            esac
        else
            state="$(gh api "repos/$repo/issues/$num" --jq .state 2>/dev/null || echo "?")"
            case "$state" in
            closed) verdict=" — ✅ **issue fermée en amont, le contournement peut sauter**" ;;
            open) verdict=" — toujours ouverte" ;;
            *) verdict=" — état inconnu" ;;
            esac
        fi
    fi

    echo "- \`$file:$line\` : $note$verdict"
done

echo
