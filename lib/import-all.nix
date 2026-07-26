# Importe récursivement tous les .nix d'un dossier, sauf le default.nix
# racine (celui qui appelle ce helper) :
#   imports = myLib.importAll ./.;
#
# CONSÉQUENCE, à respecter en ajoutant du code : sous modules/, TOUT fichier
# .nix est évalué comme module NixOS/home-manager. Un helper (fonction,
# constante, fragment de script) posé à côté d'un module y serait importé
# comme module et échouerait de façon obscure — les helpers vivent dans lib/
# et arrivent par l'argument `myLib`, jamais dans modules/.
#
# listFilesRecursive renvoie des PATHS (pas de coercition en string) : rien
# n'est copié dans le store à l'éval.
lib: dir:
builtins.filter (f: lib.hasSuffix ".nix" (toString f) && f != dir + "/default.nix") (
  lib.filesystem.listFilesRecursive dir
)
