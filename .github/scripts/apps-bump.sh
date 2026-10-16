#!/usr/bin/env bash
# Usage: IMAGES='[{"ref":…,"digest":…,"revision":…,"port":…}]' apps-bump.sh <apps.lock.json>
# Reporte des digests fournis par la CI d'une app. Sur stdout : `subject=<message de commit>`,
# vide si rien ne change. Les entrées viennent d'un appel externe : tout est vérifié avant d'écrire.
set -euo pipefail

lock="$1"
images="${IMAGES:?IMAGES manquant}"

die() {
    echo "::error::$*" >&2
    exit 1
}

jq -e 'type == "array" and length > 0 and length <= 20' <<<"$images" >/dev/null \
    || die "IMAGES doit être une liste JSON non vide de 20 entrées au plus"

# N'ajoute jamais d'image : seule une entrée déjà déclarée dans le lock peut bouger.
bad=$(jq -r --slurpfile lock "$lock" '
    .[] | . as $i | select(
        ($i | type) != "object"
        or ($i.ref | type) != "string"
        or ($lock[0] | has($i.ref) | not)
        or (($i.digest | type) != "string" or ($i.digest | test("^sha256:[0-9a-f]{64}$") | not))
        or ($i.revision != null and (($i.revision | type) != "string" or ($i.revision | test("^[0-9a-f]{7,40}$") | not)))
        or ($i.port != null and (($i.port | type) != "number" or $i.port < 1 or $i.port > 65535 or ($i.port | floor) != $i.port))
    ) | ($i.ref? // $i | tostring)' <<<"$images")
[ -z "$bad" ] || die "entrée(s) refusée(s) (absente du lock, ou digest, révision ou port mal formé) : $bad"

changed=$(jq -r --slurpfile lock "$lock" '.[] | . as $i | select($lock[0][$i.ref].digest != $i.digest or ($i.port != null and $lock[0][$i.ref].port != $i.port)) | $i.ref' <<<"$images")
if [ -z "$changed" ]; then
    echo "rien à changer : les digests sont déjà dans le lock" >&2
    exit 0
fi

tmp=$(mktemp "$lock.XXXXXX")
jq --sort-keys --indent 2 --argjson images "$images" \
    'reduce $images[] as $i (.; .[$i.ref] = {digest: $i.digest, port: ($i.port // .[$i.ref].port), revision: $i.revision})' "$lock" >"$tmp"
chmod --reference="$lock" "$tmp"
mv "$tmp" "$lock"

# `ghcr.io/nchpg/rlkart-frontend:main` -> `rlkart-frontend`.
names=$(sed -E 's#.*/##; s#:[^:]*$##' <<<"$changed" | sort -u | paste -sd, - | sed 's/,/, /g')
rev=$(jq -r '[.[].revision | select(. != null)] | unique | if length == 1 then " (\(.[0][0:7]))" else "" end' <<<"$images")
echo "subject=chore(apps): bump ${names}${rev}"
