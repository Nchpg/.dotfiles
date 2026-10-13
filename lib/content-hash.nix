# EMPREINTE DU CONTENU de la config : ne dépend que des fichiers. Une ligne
# « <chemin> <sha256> » par fichier, triées, puis le sha256 de l'ensemble.
#
# Pourquoi pas ce que Nix fournit : le `narHash` de la source et son chemin
# dans le store changent pour un même contenu selon qu'il lit un commit ou
# l'arbre de travail, et même d'une lecture de l'arbre à l'autre (vérifié).
#
# Gravée dans chaque système (modules/system/revision) ; `dotstate`
# (modules/user/shell/dotstate/dotstate.sh, contentOf) refait EXACTEMENT ce
# calcul sur un commit pour comparer. Toute modification de l'un doit se
# reporter dans l'autre.
#
# Calculée une fois par évaluation du flake (cf. flake.nix, commonArgs), et non
# par configuration : `nix flake check` en évalue huit.
lib: src:
let
  rel = f: lib.removePrefix "${toString src}/" (toString f);
  files = lib.sort (a: b: a < b) (map rel (lib.filesystem.listFilesRecursive src));
in
builtins.hashString "sha256" (
  lib.concatMapStrings (p: "${p} ${builtins.hashFile "sha256" "${src}/${p}"}\n") files
)
