#!/usr/bin/env bash
# Marqueur : commentaire commençant par `EXPIRE`, condition facultative `(option:chemin)`, puis `:` et un texte sur UNE ligne.
# URL de PR/issue dans le texte : état interrogé via `gh` (absent : liste sans verdict) ; `option:` expire quand l'option apparaît dans le nixpkgs épinglé.
set -euo pipefail

cd "${MY_FLAKE:-$(git rev-parse --show-toplevel)}"

# L'ancrage du motif évite les mentions en prose.
mapfile -t hits < <(
    git grep -n -I -E '^[[:space:]]*#[[:space:]]*EXPIRE(\([^)]*\))?:' || true
)

[ ${#hits[@]} -eq 0 ] && exit 0

# Une seule éval du flake pour toutes les conditions `option:` ; une éval cassée ne doit pas faire tomber la PR.
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

    # Motif complet retiré : le premier ':' peut être dans la parenthèse.
    note="$(echo "$text" | sed -E 's/.*EXPIRE(\([^)]*\))?:[[:space:]]*//')"
    # Un tiret final ferait doublon avec celui du verdict.
    note="$(echo "$note" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]*[-—]$//')"

    verdict=""

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
