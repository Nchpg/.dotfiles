lib:
{
  package,
  patch,
  files, # sha256 des sources NON patchées
  where,
}:
package.overrideAttrs (old: {
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
