# Auto-découverte du contenu d'un dossier, utilisé par flake.nix pour énumérer
# profiles/ et hosts/ (sous-dossiers) et devshells/ (fichiers .nix) sans liste
# à maintenir. Usage : discover = import ./lib/discover.nix lib;
lib: {
  # Noms des sous-dossiers d'un dossier (profils, hosts).
  dirNames =
    dir: lib.attrNames (lib.filterAttrs (_name: type: type == "directory") (builtins.readDir dir));

  # Noms (sans le suffixe .nix) des fichiers .nix d'un dossier plat (devshells).
  nixFileNames =
    dir:
    lib.pipe (builtins.readDir dir) [
      (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name))
      lib.attrNames
      (map (lib.removeSuffix ".nix"))
    ];
}
