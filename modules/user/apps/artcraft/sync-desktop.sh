# shellcheck shell=bash
# Seules les entrées marquées X-ArtCraft-Sync sont nettoyées.

apps_dir="$HOME/Applications"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
desktop_dir="$data/applications"
icons_dir="$data/icons"
marker="X-ArtCraft-Sync=true"

mkdir -p "$desktop_dir" "$icons_dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
shopt -s nullglob

sync_once() {
    for appimage in "$apps_dir"/*.AppImage; do
        work="$tmp/$(basename "$appimage")"
        mkdir -p "$work"
        (cd "$work" && "$appimage" --appimage-extract '*.desktop' >/dev/null \
            && "$appimage" --appimage-extract 'usr/share/icons/*' >/dev/null) || {
            [[ -e "$appimage" ]] && echo "skip $appimage : extraction impossible" >&2
            continue
        }

        for desktop in "$work"/squashfs-root/*.desktop; do
            id=$(basename "$desktop" .desktop)
            [[ "$id" == ai.storyteller.artcraft-launcher ]] && continue

            # Guillemets seulement si espace : xdg-open les prend sinon pour une partie du nom.
            awk -v app="$appimage" -v marker="$marker" '
                /^Exec=/ {
                    n = split(substr($0, 6), f, " ")
                    out = ""; done = 0
                    for (i = 1; i <= n; i++) {
                        t = f[i]
                        if (!done && t != "env" && t !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                            t = (app ~ / / ? "\"" app "\"" : app); done = 1
                        }
                        out = out (i > 1 ? " " : "") t
                    }
                    print "Exec=" out; next
                }
                /^TryExec=/ { next }
                /^\[Desktop Entry\]$/ {
                    print; print marker; print "X-ArtCraft-AppImage=" app; next
                }
                { print }
            ' "$desktop" >"$desktop_dir/$id.desktop.tmp"
            mv "$desktop_dir/$id.desktop.tmp" "$desktop_dir/$id.desktop"
        done

        if [[ -d "$work/squashfs-root/usr/share/icons" ]]; then
            cp -rT --no-preserve=mode "$work/squashfs-root/usr/share/icons" "$icons_dir"
        fi
    done

    for entry in "$desktop_dir"/*.desktop; do
        grep -qx "$marker" "$entry" || continue
        target=$(sed -n 's|^X-ArtCraft-AppImage=||p' "$entry" | head -n1)
        [[ -n "$target" ]] \
            || target=$(sed -n 's|^Exec="\([^"]*\)".*|\1|p' "$entry" | head -n1)
        [[ -n "$target" ]] || continue
        if [[ ! -e "$target" ]]; then
            icon=$(sed -n 's|^Icon=||p' "$entry" | head -n1)
            [[ -n "$icon" && "$icon" != */* ]] || icon=$(basename "$entry" .desktop)
            rm -f "$entry"
            find "$icons_dir" -name "$icon.*" -delete
        fi
    done
}

snapshot() { ls -l --time-style=+%s "$apps_dir" 2>/dev/null; }

# Un changement pendant une passe ne relance pas l'unité .path : on repasse tant que le dossier bouge.
for _ in $(seq 10); do
    before=$(snapshot)
    rm -rf "${tmp:?}"/*
    sync_once
    [[ "$(snapshot)" == "$before" ]] && break
done

update-desktop-database "$desktop_dir" 2>/dev/null || true
