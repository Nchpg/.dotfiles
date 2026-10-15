# Fige l'hôte du lien de partage DANS le bundle web de Nextcloud, cf.
# `systemSettings.nextcloud.publicSharing.canonicalLinkWebUi` pour le pourquoi
# et le coût :
#
#   myLib.server.mkNextcloudShareLinkPatch {
#     package = pkgs.nextcloud33;
#     inherit (pkgs) perl;
#     host = "cloud.exemple.fr";
#   }
#
# Le patch est un remplacement ciblé sur le seul appel qui construit ce lien,
# doublé d'une garde qui fait échouer le build si le motif n'est plus trouvé —
# le silence n'est pas une option pour du code amont minifié.
{
  package,
  perl,
  host,
}:
package.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    export NC_SHARE_HOST=${host}
    total=0
    for f in $out/dist/*.js; do
      # `~` comme délimiteur, PAS `{}` : le motif contient des accolades
      # (`\{token\}`, `[^}]`) qui fermeraient un `s{}{}` par erreur.
      # `[^}]*?` capture la valeur de baseURL — `(0,x.$_)()` ou
      # `getBaseUrl()` selon la minification — sans présumer du symbole,
      # qui change d'un bundle à l'autre. L'ancre, elle, vient du source
      # (route et noms de champs) et reste stable.
      n=$(${perl}/bin/perl -0777 -i -pe '
        BEGIN{$c=0}
        $c += s~(["\x27]/s/\{token\}["\x27],\s*\{\s*token:\s*this\.share\.token\s*\}\s*,\s*\{\s*baseURL:\s*)[^}]*?(\s*\})~$1"https://$ENV{NC_SHARE_HOST}"$2~g;
        END{print STDERR $c}
      ' "$f" 2>&1 >/dev/null)
      total=$((total + n))
    done
    echo "canonical share-link (web UI) : $total remplacement(s)"
    # GARDE. Deux occurrences exécutées (une par bundle) plus une chaîne
    # source embarquée : au moins deux. En dessous, le motif a bougé — build
    # arrêté ici plutôt que de laisser le lien redevenir le nom interne sans
    # bruit. Réajuster l'ancre dans lib/server/nextcloud-share-link-patch.nix.
    if [ "$total" -lt 2 ]; then
      echo "ERREUR canonicalLinkWebUi : motif du lien de partage introuvable (attendu >=2, obtenu $total). Le bundle Nextcloud a changé de forme ; ajuster le motif." >&2
      exit 1
    fi
  '';
})
