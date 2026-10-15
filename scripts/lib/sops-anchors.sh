# shellcheck shell=bash
# Ancres de clés age d'un .sops.yaml : les entrées de liste `- &<nom> age1…`
# qui précèdent le bloc généré, éditées à la main (une par machine et par
# plan, `<host>-sys` / `<host>-user`). Une ligne commentée qui en cite une ne
# compte pas, comme pour YAML ; le bloc généré, lui, ne fait que les citer
# (`*<nom>`).
#
# Une seule définition pour init.sh et la commande `secrets`, qui la sourcent
# l'un depuis le clone, l'autre depuis le paquet des commandes (le store :
# un script lancé sous sudo ne doit rien lire du clone à l'exécution).
ANCHOR_RE='^[[:space:]]*-[[:space:]]+&([A-Za-z0-9_-]+)[[:space:]]+(age1[a-z0-9]+)'

# anchors [fichier] : « nom<TAB>clé » par ancre, du fichier ou de l'entrée
# standard.
anchors() {
    sed -nE "s/${ANCHOR_RE}.*/\\1\\t\\2/p" "$@"
}
