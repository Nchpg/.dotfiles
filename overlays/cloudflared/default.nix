# cloudflared 2026.10.3 avant nixos-unstable : les versions antérieures à 2026.10.2 font confiance
# à des certificats intermédiaires eMudhra compromis (avis Cloudflare du 20 octobre 2026). Repris
# de nixpkgs master (seuls la version et le hash de la source changent).
#
# Sans effet dès que nixpkgs-unstable fournit 2026.10.3 ou plus : retirer alors cet overlay.
final: prev: {
  cloudflared =
    if prev.lib.versionOlder prev.cloudflared.version "2026.10.3" then
      prev.cloudflared.overrideAttrs (
        finalAttrs: _: {
          version = "2026.10.3";
          src = final.fetchFromGitHub {
            owner = "cloudflare";
            repo = "cloudflared";
            tag = finalAttrs.version;
            hash = "sha256-k1OMkHHItOT5VHhQqgC8ODm/RCJEtwtZi0Lxyf/esLg=";
          };
        }
      )
    else
      prev.cloudflared;
}
