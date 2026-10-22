#!/usr/bin/env bash
# Suit le tag de chaque image de profiles/server/apps.lock.json et y reporte son digest et son port exposé.
# Filet de sécurité : d'ordinaire, think repère lui-même une nouvelle image et déclenche apps.yml (action pin).
# Image privée : GHCR_TOKEN (portée read:packages), sinon elle est signalée et laissée telle quelle.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
# shellcheck source=scripts/lib/registry.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/registry.sh"
um_init "$@"

lock="$UM_FLAKE/profiles/server/apps.lock.json"
[ -f "$lock" ] || um_die "lock introuvable : $lock"

umask 077
REG_WORK=$(mktemp -d)
trap 'rm -rf "$REG_WORK"' EXIT

short() { if [ -n "$1" ]; then printf '%s\n' "${1:7:12}"; else echo absente; fi; }
# Le lock, plus les images de la config qui n'y sont pas encore : une nouvelle app y entre ici.
if wanted=$(nix eval --json "$UM_FLAKE#nixosConfigurations.server-think.config.systemSettings.appImages.wanted" 2>/dev/null); then
    mapfile -t refs < <({ jq -r 'keys[]' "$lock"; jq -r '.[]' <<<"$wanted"; } | sort -u)
else
    echo "⚠️ évaluation de server-think impossible : seules les images déjà dans le lock sont suivies" >&2
    mapfile -t refs < <(jq -r 'keys[]' "$lock")
fi

declare -A latest exposed
failed=()
for ref in "${refs[@]}"; do
    if [ ${#UM_ONLY[@]} -gt 0 ] && ! printf '%s\n' "${UM_ONLY[@]}" | grep -qxF "$ref"; then
        continue
    fi
    if r=$(reg_inspect "$ref" 2>/dev/null); then
        latest[$ref]=$(jq -r .digest <<<"$r")
        exposed[$ref]=$(jq -r .port <<<"$r")
    else
        failed+=("$ref")
    fi
done
note=""
[ ${#failed[@]} -gt 0 ] && note="non vérifiée(s) (privée sans GHCR_TOKEN, ou tag absent) : ${failed[*]}"

if [ "$UM_CHECK" -eq 1 ]; then
    changes="[]"
    for ref in "${!latest[@]}"; do
        current=$(jq -r --arg r "$ref" '.[$r].digest // ""' "$lock")
        port=$(jq -r --arg r "$ref" '.[$r].port' "$lock")
        [ "${latest[$ref]}" = "$current" ] && [ "${exposed[$ref]}" = "$port" ] && continue
        changes=$(jq -c --arg k "$ref" --arg c "$(short "$current")" --arg l "$(short "${latest[$ref]}")" \
            '. + [{key: $k, name: "Image · \($k)", current: $c, latest: $l, url: ""}]' <<<"$changes")
    done
    jq -nc --argjson changes "$changes" --argjson total "${#refs[@]}" --arg note "$note" '{
        name: "Images des apps",
        current: "\($total) images",
        latest: (if ($changes | length) == 0 then "\($total) images"
                 else "\($changes | length) à mettre à jour" end),
        available: (($changes | length) > 0),
        items: ($changes | sort_by(.key)),
        $note
    }' >&3
    exit 0
fi

[ -n "$note" ] && echo "⚠️ $note" >&2

updated=0
for ref in "${!latest[@]}"; do
    current=$(jq -r --arg r "$ref" '.[$r].digest // ""' "$lock")
    port=$(jq -r --arg r "$ref" '.[$r].port' "$lock")
    if [ "${latest[$ref]}" = "$current" ] && [ "${exposed[$ref]}" = "$port" ]; then
        echo "✓ $ref est à jour ($(short "$current"))"
        continue
    fi
    # La révision source n'est connue que du chemin CI (apps.yml).
    # shellcheck disable=SC2016 # $r, $d et $p sont du jq
    um_replace "$lock" jq --sort-keys --indent 2 --arg r "$ref" --arg d "${latest[$ref]}" \
        --argjson p "${exposed[$ref]}" '.[$r] = {digest: $d, port: $p, revision: null}' "$lock"
    echo "⬆️ $ref : $(short "$current") → $(short "${latest[$ref]}"), port ${exposed[$ref]}"
    updated=$((updated + 1))
done

echo "$updated image(s) mise(s) à jour."
