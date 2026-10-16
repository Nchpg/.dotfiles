#!/usr/bin/env python3
"""Indicateur SNI pour Spotify (libayatana-appindicator, visible dans waybar).

Masquer envoie la fenêtre au scratchpad de sway : la musique continue et
l'icône reste. L'icône disparaît quand plus aucune fenêtre Spotify n'existe.
"""

import fcntl
import json
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import Gtk, GLib, AyatanaAppIndicator3 as AppIndicator  # noqa: E402

PLAYER = "spotify"
# Wayland natif : seul `app_id` ; XWayland : `class`/`instance`. Pas de OR
# possible dans un critère sway, donc _walk détecte le bon.
SPOTIFY_APP_ID_CRIT = '[app_id="(?i)spotify"]'
SPOTIFY_CLASS_CRIT = '[class="(?i)spotify"]'
LOCK_PATH = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "spotify-tray-custom.lock"
)


def _run(cmd):
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def swaymsg(*args):
    _run(["swaymsg", *args])


def playerctl(*args):
    _run(["playerctl", "-p", PLAYER, *args])


def _walk(node, in_scratch):
    scratch = in_scratch or node.get("name") == "__i3_scratch"
    wp = node.get("window_properties") or {}
    app_id = (node.get("app_id") or "").lower()
    xident = " ".join(filter(None, [wp.get("class"), wp.get("instance")])).lower()
    if "spotify" in app_id:
        return True, scratch, SPOTIFY_APP_ID_CRIT
    if "spotify" in xident:
        return True, scratch, SPOTIFY_CLASS_CRIT
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        found, sc, crit = _walk(child, scratch)
        if found:
            return True, sc, crit
    return False, scratch, None


def spotify_state():
    try:
        tree = json.loads(
            subprocess.check_output(
                ["swaymsg", "-t", "get_tree"], stderr=subprocess.DEVNULL
            ).decode()
        )
    except Exception:
        return False, False, None
    return _walk(tree, False)


def spotify_running():
    return spotify_state()[0]


def launch_spotify():
    env = dict(os.environ)
    lib = env.get("SPOTIFY_ADBLOCK_LIB")
    if lib:
        existing = env.get("LD_PRELOAD", "")
        env["LD_PRELOAD"] = f"{lib}:{existing}" if existing else lib
    subprocess.Popen(
        ["spotify"], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def _reveal_or_launch():
    running, hidden, crit = spotify_state()
    if not running:
        launch_spotify()
        return False, None
    elif hidden:
        swaymsg(crit, "scratchpad", "show")
        return False, crit
    else:
        return True, crit


def show_window(_=None):
    was_visible, crit = _reveal_or_launch()
    if was_visible and crit:
        swaymsg(crit, "focus")


def toggle_window(_=None):
    was_visible, crit = _reveal_or_launch()
    if was_visible and crit:  # était visible -> on masque
        swaymsg(crit, "move", "scratchpad")


def metadata():
    try:
        out = (
            subprocess.check_output(
                ["playerctl", "-p", PLAYER, "metadata", "--format",
                 "{{artist}} - {{title}}"],
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
        return out if out and out != "-" else "Spotify"
    except Exception:
        return "Spotify"


_lock = open(LOCK_PATH, "w")
try:
    fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    show_window()
    sys.exit(0)


def quit_all(_=None):
    crit = spotify_state()[2] or SPOTIFY_APP_ID_CRIT
    swaymsg(crit, "kill")
    Gtk.main_quit()


if not spotify_running():
    launch_spotify()

indicator = AppIndicator.Indicator.new(
    "spotify-tray-custom",
    "spotify-client",
    AppIndicator.IndicatorCategory.APPLICATION_STATUS,
)
indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

menu = Gtk.Menu()


def add(label, callback):
    item = Gtk.MenuItem(label=label)
    item.connect("activate", callback)
    menu.append(item)
    return item


toggle_item = add("Masquer", toggle_window)
menu.append(Gtk.SeparatorMenuItem())
add("Lecture / Pause", lambda _: playerctl("play-pause"))
add("Suivant", lambda _: playerctl("next"))
add("Précédent", lambda _: playerctl("previous"))
menu.append(Gtk.SeparatorMenuItem())
add("Quitter", quit_all)
menu.show_all()

indicator.set_menu(menu)
indicator.set_secondary_activate_target(toggle_item)

seen_running = False
_waited = 0


def tick():
    """Garde l'icône tant qu'une fenêtre Spotify existe ; délai de grâce au démarrage."""
    global seen_running, _waited
    running, hidden, _crit = spotify_state()
    if running:
        seen_running = True
        indicator.set_title(metadata())
        toggle_item.set_label("Afficher" if hidden else "Masquer")
    elif seen_running:
        Gtk.main_quit()
        return False
    else:
        _waited += 1
        if _waited > 15:  # ~30 s sans Spotify -> abandon
            Gtk.main_quit()
            return False
    return True


tick()
GLib.timeout_add_seconds(2, tick)
Gtk.main()
