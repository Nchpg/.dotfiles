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
# Critère sway ciblant la fenêtre Spotify. En Wayland natif (NIXOS_OZONE_WL=1)
# la fenêtre n'expose QUE `app_id` ; sous XWayland elle expose `class`/`instance`.
# On ne peut pas OR ces deux propriétés dans un seul critère sway, donc on
# détermine le bon critère au runtime (cf. _walk / spotify_crit) et on garde
# app_id comme repli par défaut (mode Wayland natif).
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
    """Cherche une fenêtre Spotify. Renvoie (trouvée?, dans_le_scratchpad?,
    critère_sway). Le critère reflète comment la fenêtre s'identifie : app_id
    (Wayland natif) ou class (XWayland), pour que les commandes swaymsg ciblent
    bien la fenêtre quel que soit le mode de rendu."""
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
    """(running, hidden, crit) : running = une fenêtre Spotify existe (même cachée
    au scratchpad) ; hidden = elle est dans le scratchpad ; crit = critère sway
    pour la cibler (None si absente)."""
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
    s'il est caché. Renvoie (était_déjà_visible, critère_sway). Le critère est
    None quand on vient de lancer Spotify (pas encore de fenêtre)."""
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
    """Affiche Spotify (focus sa fenêtre / le ramène / le relance)."""
    was_visible, crit = _reveal_or_launch()
    if was_visible and crit:
        swaymsg(crit, "focus")


def toggle_window(_=None):
    """Bascule affiché <-> masqué. Masquer = scratchpad (musique + icône
    conservées). Afficher = ramener/relancer."""
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
    crit = spotify_state()[2] or SPOTIFY_APP_ID_CRIT
    swaymsg(crit, "kill")
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
