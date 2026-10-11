# Entrées de menu des apps installées par le launcher dans ~/Applications.
#
# Ni le launcher ni la plupart des apps (PdfCraft notamment) ne les créent pour
# une AppImage : sans elles, rien dans rofi. On reprend le .desktop et les
# icônes embarqués dans chaque AppImage, avec Exec pointé sur le fichier (son
# nom change à chaque MAJ, d'où la resynchro à chaque changement du dossier,
# cf. l'unité .path). Lancement direct : nix-ld fournit les libs Wayland/Vulkan.
#
# Seules les entrées marquées X-ArtCraft-Sync sont nettoyées : rien d'autre
# dans ~/.local/share/applications n'est touché.

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
        # --appimage-extract : runtime statique, ni FUSE ni nix-ld nécessaires.
        (cd "$work" && "$appimage" --appimage-extract '*.desktop' >/dev/null \
            && "$appimage" --appimage-extract 'usr/share/icons/*' >/dev/null) || {
            # Supprimée entre-temps (ancienne version remplacée par une MAJ) :
            # normal, la passe suivante s'en occupe.
            [[ -e "$appimage" ]] && echo "skip $appimage : extraction impossible" >&2
            continue
        }

        for desktop in "$work"/squashfs-root/*.desktop; do
            id=$(basename "$desktop" .desktop)
            # Le launcher lui-même est fourni par Nix : une copie ici masquerait
            # son entrée.
            [[ "$id" == ai.storyteller.artcraft-launcher ]] && continue

            sed -e "s|^Exec=[^ ]*|Exec=\"$appimage\"|" \
                -e '/^TryExec=/d' \
                "$desktop" >"$desktop_dir/$id.desktop.tmp"
            echo "$marker" >>"$desktop_dir/$id.desktop.tmp"
            mv "$desktop_dir/$id.desktop.tmp" "$desktop_dir/$id.desktop"
        done

        if [[ -d "$work/squashfs-root/usr/share/icons" ]]; then
            cp -rT --no-preserve=mode "$work/squashfs-root/usr/share/icons" "$icons_dir"
        fi
    done

    # Entrées dont l'AppImage a disparu (app désinstallée ; une MAJ, elle, a déjà
    # réécrit l'entrée sous le même id ci-dessus).
    for entry in "$desktop_dir"/*.desktop; do
        grep -qx "$marker" "$entry" || continue
        target=$(sed -n 's|^Exec="\([^"]*\)".*|\1|p' "$entry" | head -n1)
        if [[ ! -e "$target" ]]; then
            id=$(basename "$entry" .desktop)
            rm -f "$entry"
            find "$icons_dir" -name "$id.*" -delete
        fi
    done
}

# État du dossier (noms, tailles, dates).
snapshot() { ls -l --time-style=+%s "$apps_dir" 2>/dev/null; }

# Un changement de ~/Applications PENDANT une passe ne relance pas l'unité
# .path (service encore actif) : il serait perdu. Arrive dès que le launcher
# installe ou met à jour plusieurs apps d'affilée. On repasse tant que le
# dossier a bougé. Le script n'écrit jamais dans ~/Applications, et les
# copies en cours du launcher (.<nom>.partial, cachées) échappent à `ls -l` :
# seules de vraies installs successives prolongent la boucle. Plafond par
# sécurité ; au-delà, le prochain changement relancera de toute façon l'unité.
for _ in $(seq 10); do
    before=$(snapshot)
    rm -rf "${tmp:?}"/*
    sync_once
    [[ "$(snapshot)" == "$before" ]] && break
done

update-desktop-database "$desktop_dir" 2>/dev/null || true
