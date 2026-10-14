#!/usr/bin/env bash
# Vérifie la dernière version de tasks-tui-app sur PyPI et met à jour
# pinned.json avec le hash SRI du sdist. Pas de téléchargement : PyPI publie
# le sha256 du fichier, converti tel quel au format attendu par fetchPypi.
# Protocole : cf. scripts/lib/update-module.sh.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest tasks-tui-app version (PyPI)..."
version=$(um_latest_pypi tasks-tui-app)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "tasks-tui" "$current" "$version" \
    "https://pypi.org/project/tasks-tui-app/$version/"
um_skip_if_current "tasks-tui-app" "$current" "$version"

# Le sdist, celui que fetchPypi télécharge (pas la wheel).
echo "🔎 Reading sdist hash for $version..."
if ! hex=$(um_curl "https://pypi.org/pypi/tasks-tui-app/${version}/json" \
    | jq -er '[.urls[] | select(.packagetype == "sdist")][0].digests.sha256') \
    || ! hash=$(nix hash convert --hash-algo sha256 --to sri "$hex"); then
    um_die "Could not retrieve sdist hash for tasks-tui-app"
fi
um_write_pinned version="$version" hash="$hash"

echo "⬆️ Updated tasks-tui-app to version $version"
