# shellcheck shell=bash

hooks_present() { [ -d "$1/.githooks" ]; }

hooks_on() { [ "$(git -C "$1" config --get core.hooksPath 2>/dev/null || true)" = .githooks ]; }

hooks_enable() { git -C "$1" config core.hooksPath .githooks; }

hooks_status() {
    hooks_present "$1" || return 0
    if hooks_on "$1"; then
        printf '%s✓ hooks git actifs : secrets synchronisés au pull et au push%s\n' "$OK" "$R"
    else
        printf '%s⚠ hooks git INACTIFS dans %s : secrets non synchronisés au pull/push%s\n' "$WARN" "$1" "$R"
    fi
}

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
