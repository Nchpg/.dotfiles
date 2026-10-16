# Une clé retirée du JSON déclaratif n'est jamais retirée du fichier cible.
{
  lib,
  pkgs,
  targetPath,
  sourceFile,
  label,
}:
''
  target=${lib.escapeShellArg targetPath}
  mkdir -p "$(dirname "$target")"
  if [ -s "$target" ]; then
    if ${pkgs.jq}/bin/jq -e . "$target" >/dev/null 2>&1; then
      if ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$target" ${sourceFile} > "$target.hm-tmp"; then
        # Garde le mode du fichier existant (0600 possible : jetons).
        chmod --reference="$target" "$target.hm-tmp" 2>/dev/null || true
        mv "$target.hm-tmp" "$target"
      else
        rm -f "$target.hm-tmp"
        echo "${label}: échec du merge JSON de $target — fichier laissé intact." >&2
      fi
    else
      echo "${label}: $target n'est pas du JSON strict (édité à la main ?) — clés déclaratives non imposées." >&2
    fi
  else
    # 0600 : le fichier peut contenir des jetons.
    install -m600 ${sourceFile} "$target"
  fi
''
