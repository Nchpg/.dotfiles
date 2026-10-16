# shellcheck shell=bash
ANCHOR_RE='^[[:space:]]*-[[:space:]]+&([A-Za-z0-9_-]+)[[:space:]]+(age1[a-z0-9]+)'

anchors() {
    sed -nE "s/${ANCHOR_RE}.*/\\1\\t\\2/p" "$@"
}
