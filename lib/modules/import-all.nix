# Sous modules/, TOUT fichier .nix est évalué comme module : les helpers vivent dans lib/.
lib: dir:
builtins.filter (f: lib.hasSuffix ".nix" (toString f) && f != dir + "/default.nix") (
  lib.filesystem.listFilesRecursive dir
)
