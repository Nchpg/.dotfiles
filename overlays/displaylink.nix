# Le paquet displaylink de nixpkgs utilise requireFile (licence Synaptics à
# accepter à la main via nix-prefetch-url, une fois par host). L'URL étant
# téléchargeable directement, on remplace le src par un fetchurl : le rebuild
# récupère le zip tout seul, sur n'importe quel host.
# Appliqué sur pkgs-stable dans flake.nix (nixpkgs.overlays serait ignoré,
# cf. modules/system/configuration.nix). Vit hors de modules/ car
# lib/import-all.nix chargerait tout .nix de là-bas comme module NixOS.
# Seule l'URL est à maintenir quand nixpkgs bump displaylink : `name` et
# `hash` sont repris du requireFile amont (il expose outputHash), donc ils
# suivent le bump tout seuls. Conséquence voulue : si l'URL n'est PAS mise à
# jour en même temps, on échoue sur un mismatch de hash explicite — au lieu de
# l'ancien symptôme, un `chmod: No such file or directory` opaque dû au
# désaccord entre `version` (amont, bumpée) et le zip (figé ici), car l'amont
# dérive le nom du .run de `version`.
# NB : contourner le requireFile revient à court-circuiter l'acceptation
# explicite de l'EULA Synaptics — choix assumé pour un dépôt personnel.
final: prev: {
  displaylink = prev.displaylink.overrideAttrs (old: {
    src = final.fetchurl {
      inherit (old.src) name;
      hash = old.src.outputHash;
      url = "https://www.synaptics.com/sites/default/files/exe_files/2025-09/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.2-EXE.zip";
    };
  });
}
