# Applique un patch local à un paquet SEULEMENT si les fichiers qu'il modifie
# sont EXACTEMENT ceux contre lesquels il a été écrit et testé (empreintes
# sha256 des sources non patchées). Utilisé pour sway (overlays/sway) et
# swaylock-effects (modules/user/window-manager/sway/lock).
#
# Un bump qui ne touche pas ces fichiers passe sans rien demander ; un bump qui
# les touche arrête le build en les nommant — même si le patch s'appliquerait
# encore, car un fichier au sens changé pourrait compiler ET mal se comporter.
# Dans ce cas : relire le patch contre la nouvelle version, le retester, puis
# mettre à jour les empreintes (`sha256sum` sur les sources non patchées).
lib:
{
  package,
  patch, # chemin du .patch
  files, # { "chemin/relatif" = "sha256"; } des sources NON patchées
  where, # fichier qui porte les empreintes, cité dans le message d'échec
}:
package.overrideAttrs (old: {
  # prePatch : sources encore vierges, avant les patchs nixpkgs et le nôtre.
  prePatch = (old.prePatch or "") + ''
    if ! sha256sum --check --quiet <<'EOF'
    ${lib.concatStrings (lib.mapAttrsToList (path: hash: "${hash}  ${path}\n") files)}EOF
    then
      echo "${baseNameOf patch} : les fichiers ci-dessus ont changé dans ${old.pname or old.name} ''${version}." >&2
      echo "Relire et retester le patch, puis mettre à jour les empreintes" >&2
      echo "(${where})." >&2
      exit 1
    fi
  '';
  patches = (old.patches or [ ]) ++ [ patch ];
})
