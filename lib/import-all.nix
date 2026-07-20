# Importe récursivement tous les .nix d'un dossier, sauf le default.nix
# racine (celui qui appelle ce helper) :
#   imports = import ../../lib/import-all.nix lib ./.;
#
# listFilesRecursive renvoie des PATHS (pas de coercition en string) : rien
# n'est copié dans le store à l'éval.
lib: dir:
builtins.filter (f: lib.hasSuffix ".nix" (toString f) && f != dir + "/default.nix") (
  lib.filesystem.listFilesRecursive dir
)
