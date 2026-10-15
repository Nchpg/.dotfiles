# Source épinglée par un update.sh de module : fetchurl sur l'URL et le hash
# SRI que le script a écrits dans pinned.json. L'URL n'existe qu'à un seul
# endroit (le script qui la calcule), plus de copie à tenir alignée côté Nix.
# Le reste du fichier (version...) se lit à part par le module.
#
#   src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;
lib: pkgs: file:
pkgs.fetchurl { inherit (lib.importJSON file) url hash; }
