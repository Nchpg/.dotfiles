# Le paquet displaylink de nixpkgs utilise requireFile (licence Synaptics à
# accepter à la main). L'URL étant téléchargeable directement, on remplace le
# src par un fetchurl : le rebuild récupère le zip tout seul, sur n'importe
# quel host. Appliqué sur pkgs-stable dans flake.nix (nixpkgs.overlays serait
# ignoré). Vit hors de modules/ : lib/modules/import-all.nix chargerait tout .nix de
# là-bas comme module NixOS.
# Seule l'URL est à maintenir au bump nixpkgs : `name`/`hash` suivent le
# requireFile amont automatiquement, donc un désaccord URL/version échoue sur
# un mismatch de hash explicite plutôt qu'un `chmod: No such file` opaque.
# NB : contourne l'acceptation explicite de l'EULA Synaptics — assumé pour un
# dépôt personnel.
final: prev: {
  displaylink = prev.displaylink.overrideAttrs (old: {
    src = final.fetchurl {
      inherit (old.src) name;
      hash = old.src.outputHash;
      url = "https://www.synaptics.com/sites/default/files/exe_files/2025-09/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.2-EXE.zip";
    };
  });
}
