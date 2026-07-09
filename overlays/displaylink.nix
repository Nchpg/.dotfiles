# Le paquet displaylink de nixpkgs utilise requireFile (licence Synaptics à
# accepter à la main via nix-prefetch-url, une fois par host). L'URL étant
# téléchargeable directement, on remplace le src par un fetchurl : le rebuild
# récupère le zip tout seul, sur n'importe quel host.
# Appliqué sur pkgs-stable dans flake.nix (nixpkgs.overlays serait ignoré,
# cf. modules/system/configuration.nix). Vit hors de modules/ car
# lib/import-all.nix chargerait tout .nix de là-bas comme module NixOS.
# À mettre à jour quand nixpkgs bump displaylink : nouveau nom/URL/hash
# (le message d'erreur du build donne l'URL, `nix hash convert` pour le hash).
final: prev: {
  displaylink = prev.displaylink.overrideAttrs {
    src = final.fetchurl {
      name = "displaylink-620.zip";
      url = "https://www.synaptics.com/sites/default/files/exe_files/2025-09/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.2-EXE.zip";
      hash = "sha256-JQO7eEz4pdoPkhcn9tIuy5R4KyfsCniuw6eXw/rLaYE=";
    };
  };
}
