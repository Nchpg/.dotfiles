# Importe récursivement tous les fichiers .nix d'un dossier de modules, sauf le
# default.nix racine (celui qui appelle ce helper). Utilisé par
# modules/system/default.nix et modules/user/default.nix :
#   imports = import ../../lib/import-all.nix lib ./.;
#
# listFilesRecursive renvoie des PATHS (pas de coercition en string) : rien
# n'est copié dans le store à l'éval — même garantie que l'ancienne
# implémentation manuelle (getDir/collect), en trois lignes.
lib: dir:
builtins.filter (f: lib.hasSuffix ".nix" (toString f) && f != dir + "/default.nix") (
  lib.filesystem.listFilesRecursive dir
)
