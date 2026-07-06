# Importe récursivement tous les fichiers .nix d'un dossier de modules, sauf le
# default.nix racine (celui qui appelle ce helper). Utilisé par
# modules/system/default.nix et modules/user/default.nix :
#   imports = import ../../lib/import-all.nix lib ./.;
lib: dir:
let
  getDir =
    d:
    lib.mapAttrs (file: type: if type == "directory" then getDir "${d}/${file}" else type) (
      builtins.readDir d
    );

  files =
    d:
    lib.collect lib.isString (
      lib.mapAttrsRecursive (path: _type: lib.concatStringsSep "/" path) (getDir d)
    );
in
map (file: dir + "/${file}") (
  lib.filter (file: lib.hasSuffix ".nix" file && file != "default.nix") (files dir)
)
