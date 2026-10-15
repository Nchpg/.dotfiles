# sway-unwrapped patché (./sway-smooth-lock.patch). Appliqué sur pkgs-stable
# dans flake.nix, comme displaylink : TOUT sway de ce jeu de paquets en
# hérite — le wrapper du module système (modules/system/window-manager/sway)
# comme le swaymsg tiré côté user —, donc une seule compilation de sway et
# plus de second sway non patché à côté. Vit hors de modules/ :
# lib/import-all.nix chargerait tout .nix de là-bas comme module NixOS.
#
# Patch : au verrouillage, sway pose un fond noir opaque sur chaque sortie
# AVANT que le locker ait dessiné, d'où un flash noir (~66 ms) avant le
# fondu de swaylock. Le fond n'apparaît plus qu'une fois la surface du locker
# affichée sur la sortie. Garde-fous :
#   - 200 ms sans image du locker -> fond opaque partout quand même ;
#   - locker mort (abandon) -> fond rouge immédiat, comme en amont ;
#   - sortie branchée après le timeout -> opaque d'emblée.
# Pendant cette fenêtre, l'input va déjà au seul locker (seat.c) : le
# bureau reste visible un instant mais n'est plus interactif.
#
# Conséquences : sway n'est plus servi par le cache (recompilé à chaque
# bump, ~1 min), et un bump qui touche sway/lock.c fait échouer le build
# sur l'application du patch — à rebaser alors, ou à retirer.
#
# Garde-fou (cf. lib/mk-guarded-patch.nix) : empreintes des sources de
# sway 1.12 contre lesquelles le patch a été écrit. Si elles changent :
# relire le patch, le retester (sway imbriqué : verrou filmé, écran
# branché/débranché, locker tué), puis mettre à jour les empreintes.
myLib: _final: prev: {
  sway-unwrapped = myLib.mkGuardedPatch {
    package = prev.sway-unwrapped;
    patch = ./sway-smooth-lock.patch;
    files = {
      "sway/lock.c" = "d147eebafe77eb2986a49dffa7a12f88d50e8793e158aa1a28192771a70a10f5";
      "include/sway/server.h" = "80af1b5ae13164f4d09851201a931d8aea7a3838b093391fc94e8337e4c1d3e5";
    };
    where = "overlays/sway/default.nix";
  };
}
