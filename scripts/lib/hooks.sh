# shellcheck shell=bash
# LES HOOKS GIT du dépôt de config (.githooks) : formatage au commit, et
# surtout le dépôt de secrets tenu en phase au pull et au push (cf. `secrets
# git-hook`). Actifs seulement si le clone le demande (core.hooksPath,
# réglage local jamais poussé) : un clone fait à la main sans ./init.sh les a
# donc éteints. Sans eux, un push depuis cette machine pourrait publier un
# lock que le serveur ne sait pas récupérer.
#
# Une seule implémentation pour les trois endroits qui s'en occupent :
# init.sh (les active), rebuild.sh (les rattrape après un rebuild, quand la
# commande `secrets` qu'ils appellent est à jour) et `dots` (état + activation
# proposée). Suppose scripts/lib/ui.sh déjà sourcé (couleurs, confirm).

# Le dépôt a-t-il des hooks à activer ?
hooks_present() { [ -d "$1/.githooks" ]; }

hooks_on() { [ "$(git -C "$1" config --get core.hooksPath 2>/dev/null || true)" = .githooks ]; }

hooks_enable() { git -C "$1" config core.hooksPath .githooks; }

# Une ligne d'état, colorée (rien si le dépôt n'a pas de hooks).
hooks_status() {
    hooks_present "$1" || return 0
    if hooks_on "$1"; then
        printf '%s✓ hooks git actifs : secrets synchronisés au pull et au push%s\n' "$OK" "$R"
    else
        printf '%s⚠ hooks git INACTIFS dans %s : secrets non synchronisés au pull/push%s\n' "$WARN" "$1" "$R"
    fi
}

# hooks_offer <dépôt> [--no-ask] : rien s'ils sont actifs ; sinon l'état,
# puis l'activation proposée (Oui par défaut), ou seulement la commande à
# taper sans terminal ou avec --no-ask (`rebuild --yes` ne décide pas à ta
# place).
hooks_offer() {
    local repo="$1"
    hooks_present "$repo" && ! hooks_on "$repo" || return 0
    hooks_status "$repo"
    if [ "${2:-}" = --no-ask ] || [ ! -t 0 ]; then
        echo "  Pour les activer : git -C $repo config core.hooksPath .githooks"
    elif confirm "Activer les hooks git maintenant ?" yes; then
        hooks_enable "$repo"
        hooks_status "$repo"
    fi
}
