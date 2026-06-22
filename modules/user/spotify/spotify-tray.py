#!/usr/bin/env python3
"""Indicateur SNI maison pour Spotify (vrai StatusNotifierItem via
libayatana-appindicator, visible dans waybar — contrairement à spotify-tray qui
ne fait que du XEmbed invisible sous Sway).

Idée : « fermer l'interface sans couper la musique ». Masquer Spotify l'envoie
au scratchpad de sway -> la fenêtre disparaît de l'écran MAIS le process et la
musique continuent, et la fenêtre reste dans l'arbre sway (donc l'icône reste).
Seul « Quitter » (clic droit) ou un pkill arrête vraiment Spotify.

Cycle de vie :
  - De base : rien (aucun démon au login).
  - Ouvrir « Spotify » (l'entrée de menu pointe sur ce binaire) : 1er lancement
    -> verrou + lancement de Spotify + icône.
  - Masquer : la fenêtre va au scratchpad (musique conservée, icône conservée).
  - Afficher : ramène/relance la fenêtre.
  - Quitter / pkill : Spotify s'arrête -> plus de fenêtre -> l'icône disparaît.
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
SPOTIFY_CRIT = '[class="(?i)spotify"]'  # critère sway (Spotify tourne en XWayland)
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
    """Cherche une fenêtre Spotify. Renvoie (trouvée?, dans_le_scratchpad?)."""
    scratch = in_scratch or node.get("name") == "__i3_scratch"
    wp = node.get("window_properties") or {}
    ident = " ".join(
        filter(None, [wp.get("class"), wp.get("instance"), node.get("app_id")])
    )
    if "spotify" in ident.lower():
        return True, scratch
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        found, sc = _walk(child, scratch)
        if found:
            return True, sc
    return False, scratch


def spotify_state():
    """(running, hidden) : running = une fenêtre Spotify existe (même cachée au
    scratchpad) ; hidden = elle est dans le scratchpad."""
    try:
        tree = json.loads(
            subprocess.check_output(
                ["swaymsg", "-t", "get_tree"], stderr=subprocess.DEVNULL
            ).decode()
        )
    except Exception:
        return False, False
    return _walk(tree, False)


def spotify_running():
    return spotify_state()[0]


def launch_spotify():
    # Précharge spotify-adblock (LD_PRELOAD) uniquement pour Spotify : blocage
    # des pubs au niveau réseau, sans toucher au player. Le chemin du .so est
    # fourni par le wrapper Nix via SPOTIFY_ADBLOCK_LIB.
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
    """Rend Spotify visible : le lance s'il n'existe pas, le sort du scratchpad
    s'il est caché. Renvoie True si la fenêtre était DÉJÀ visible (rien fait)."""
    running, hidden = spotify_state()
    if not running:
        launch_spotify()
    elif hidden:
        swaymsg(SPOTIFY_CRIT, "scratchpad", "show")
    else:
        return True
    return False


def show_window(_=None):
    """Affiche Spotify (focus sa fenêtre / le ramène / le relance)."""
    if _reveal_or_launch():
        swaymsg(SPOTIFY_CRIT, "focus")


def toggle_window(_=None):
    """Bascule affiché <-> masqué. Masquer = scratchpad (musique + icône
    conservées). Afficher = ramener/relancer."""
    if _reveal_or_launch():  # était visible -> on masque
        swaymsg(SPOTIFY_CRIT, "move", "scratchpad")


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


# --- Singleton : un seul indicateur à la fois -------------------------------
_lock = open(LOCK_PATH, "w")
try:
    fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    # Indicateur déjà présent : ce 2e lancement sert juste à afficher Spotify.
    show_window()
    sys.exit(0)


def quit_all(_=None):
    # Arrêt total : ferme la fenêtre Spotify (-> il quitte), puis sort.
    swaymsg(SPOTIFY_CRIT, "kill")
    Gtk.main_quit()


# Premier lancement : on ouvre Spotify.
if not spotify_running():
    launch_spotify()

indicator = AppIndicator.Indicator.new(
    "spotify-tray-custom",
    # Le paquet Spotify installe l'icône sous le nom "spotify-client".
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
# Clic « secondaire » (molette/milieu selon le host) -> bascule afficher/masquer.
indicator.set_secondary_activate_target(toggle_item)

seen_running = False
_waited = 0


def tick():
    """Tant qu'une fenêtre Spotify existe (même cachée au scratchpad), on garde
    l'icône. Quand il n'y en a plus (Quitter/pkill), on sort -> icône retirée.
    Délai de grâce au démarrage le temps que Spotify s'ouvre."""
    global seen_running, _waited
    running, hidden = spotify_state()
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
