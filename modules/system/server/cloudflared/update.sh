#!/usr/bin/env bash
# Épingle la dernière release de cloudflared (source + vendorHash) ; le module garde
# nixpkgs-unstable s'il est aussi récent.
set -euo pipefail
# shellcheck source=scripts/lib/update-module.sh
. "${MY_FLAKE:-$HOME/.dotfiles}/scripts/lib/update-module.sh"
um_init "$@"

echo "🔎 Checking latest cloudflared release..."
version=$(um_latest_gh_release cloudflare/cloudflared)
echo "Latest version: $version"

current=$(um_pinned version)
[ "$UM_CHECK" -eq 1 ] && um_check "cloudflared" "$current" "$version" \
    "https://github.com/cloudflare/cloudflared/releases/tag/$version"
um_skip_if_current "cloudflared" "$current" "$version"

echo "🔎 Fetching + hashing sources for $version..."
hash=$(um_prefetch_gh cloudflare/cloudflared "$version")

# Avec le Go de nixpkgs-unstable : une release qui exige un Go plus récent échoue ici, et
# l'épinglage précédent reste en place.
echo "🔎 Computing vendorHash (vendoring Go modules)..."
expr="let
  flake = builtins.getFlake \"$UM_FLAKE\";
  pkgs = import flake.inputs.nixpkgs-unstable { system = builtins.currentSystem; };
in (pkgs.cloudflared.overrideAttrs (finalAttrs: _: {
  version = \"$version\";
  src = pkgs.fetchFromGitHub {
    owner = \"cloudflare\";
    repo = \"cloudflared\";
    tag = finalAttrs.version;
    hash = \"$hash\";
  };
  vendorHash = pkgs.lib.fakeHash;
})).goModules"
# Échec attendu : le vrai hash est dans le « got: » de la dérivation go-modules (pas celui
# d'une source au hash faux, qui échouerait avant).
build_log=$(nix build --no-link --impure --expr "$expr" 2>&1 || true)
vendor_hash=$(printf '%s\n' "$build_log" \
    | awk '/hash mismatch in fixed-output derivation .*-go-modules\.drv/ { m = 1 } m && $1 == "got:" { print $2; exit }')
if [ -z "$vendor_hash" ]; then
    printf '%s\n' "$build_log" | tail -n 20 >&2
    um_die "Could not compute vendorHash for cloudflared $version"
fi
um_write_pinned version="$version" hash="$hash" vendorHash="$vendor_hash"

echo "⬆️ Updated cloudflared to version $version"
