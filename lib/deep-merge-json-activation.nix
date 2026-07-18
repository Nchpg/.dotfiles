# Script de home.activation qui deep-merge un JSON déclaratif dans un fichier
# qu'une app tierce peut aussi écrire elle-même (Claude Code, VS Code...). Nos
# clés (sourceFile) l'emportent sur l'existant ; le reste de l'existant est
# préservé (un symlink read-only du store casserait ces écritures runtime).
# Si le fichier existant n'est pas du JSON strict (édition manuelle avec
# commentaires, JSONC...), on n'impose rien et on prévient plutôt que de
# l'écraser. Utilisé par modules/user/claude et modules/user/vscode.
#
# Limite assumée du merge one-way : une clé RETIRÉE du JSON déclaratif n'est
# jamais retirée du fichier cible (elle y reste avec sa dernière valeur).
# Pour la supprimer vraiment : l'effacer à la main dans le fichier cible.
{
  lib,
  pkgs,
  # Chemin ABSOLU du fichier cible (ex. "${config.home.homeDirectory}/.claude/settings.json").
  targetPath,
  # Dérivation/chemin du JSON déclaratif à imposer.
  sourceFile,
  # Nom affiché dans le message d'avertissement (ex. "claude", "vscode").
  label,
}:
''
  target=${lib.escapeShellArg targetPath}
  mkdir -p "$(dirname "$target")"
  if [ -s "$target" ]; then
    if ${pkgs.jq}/bin/jq -e . "$target" >/dev/null 2>&1; then
      # deep-merge : existant (.[0]) * nos clés (.[1]) — les nôtres l'emportent.
      # En cas d'échec du jq (disque plein...), on nettoie le tmp au lieu de
      # laisser un $target.hm-tmp orphelin.
      if ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$target" ${sourceFile} > "$target.hm-tmp"; then
        # Le tmp naît avec le umask courant (0644) : sans ce report, un fichier
        # volontairement durci en 0600 — ~/.claude/settings.json peut contenir
        # des jetons — repasserait monde-lisible à CHAQUE activation.
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
    install -m644 ${sourceFile} "$target"
  fi
''
