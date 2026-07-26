#!/usr/bin/env python3
"""Sert la galerie des thèmes et applique un choix dans la config.

    server.py <galerie.html> <manifeste.json> <profil.nix> <favoris.json>

Une page ouverte en file:// ne peut pas écrire sur le disque : d'où ce
serveur, qui vit le temps d'un choix. Il écoute sur 127.0.0.1 uniquement,
sur un port éphémère, et exige un jeton aléatoire régénéré à chaque
lancement — sans quoi n'importe quel processus local (le compte `guest`
existe sur cette machine) pourrait POSTer et réécrire la config.

Codes de sortie, lus par la commande `theme` :
  0 — un thème a été appliqué (le détail est écrit sur stdout)
  2 — fermé sans rien appliquer (Ctrl-C ou timeout)
  1 — erreur
"""

import http.server
import json
import os
import re
import secrets
import socketserver
import subprocess
import sys
import threading
import webbrowser

# Au-delà, on considère que la fenêtre a été abandonnée : on rend la main
# plutôt que de laisser un serveur ouvert indéfiniment.
IDLE_TIMEOUT_SECONDS = 15 * 60

SLOTS = {"dark": "darkTheme", "light": "lightTheme"}


def js_string_body(value):
    """json.dumps(value), échappé pour tenir dans un littéral JS '...'.

    CURRENT/FAVORITES sont réinjectés tels quels dans la page (cf.
    do_GET/main) à l'intérieur de `JSON.parse('__PLACEHOLDER__')`. JSON
    n'échappe pas le guillemet simple (seul `"` l'est), donc un nom de thème
    contenant une apostrophe casserait le littéral JS ; le tout vit en plus
    dans un <script>, donc une séquence `</script` briserait la balise avant
    même que le JS ne s'exécute. Les deux échappements ci-dessous couvrent
    ces deux cas (le risque réel est quasi nul ici — noms de thèmes issus
    d'un manifeste connu — mais le coût de le couvrir est négligeable).
    """
    encoded = json.dumps(value)
    encoded = encoded.replace("\\", "\\\\").replace("'", "\\'")
    return encoded.replace("</", "<\\/")


class Applied(Exception):
    """Levée pour arrêter le serveur une fois le choix appliqué."""


def read_current(profile_path):
    """Thèmes actuellement déclarés dans le profil, par slot.

    Sert à mettre en avant les thèmes actifs dans la galerie. Un slot absent
    ou déclaré plusieurs fois est simplement omis : c'est de la décoration,
    ça ne doit jamais empêcher la galerie de s'ouvrir.
    """
    try:
        with open(profile_path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return {}

    current = {}
    for slot, option in SLOTS.items():
        matches = re.findall(rf'\b{option}\s*=\s*"([^"]*)";', content)
        if len(matches) == 1:
            current[slot] = matches[0]
    return current


def read_favorites(favorites_path):
    """Liste des thèmes en favori. Tolérante : un fichier absent ou abîmé
    donne une liste vide plutôt que d'empêcher la galerie de s'ouvrir."""
    try:
        with open(favorites_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    return [str(x) for x in data] if isinstance(data, list) else []


def write_favorites(favorites_path, names):
    """Réécrit le fichier de favoris (trié, une entrée par ligne).

    Trié pour que le diff git soit stable : sans ça, l'ordre de clic
    produirait des diffs illisibles à chaque session.
    """
    payload = json.dumps(sorted(set(names)), indent=2, ensure_ascii=False) + "\n"
    tmp = favorites_path + ".theme-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(payload)
    os.replace(tmp, favorites_path)


def apply_to_profile(profile_path, slot, name):
    """Remplace `<slot>Theme = "...";` dans le fichier de profil.

    Renvoie (ancien_nom, nouveau_nom). Lève ValueError si le champ est
    absent ou présent plusieurs fois — mieux vaut échouer que réécrire au
    petit bonheur un fichier de config.
    """
    option = SLOTS[slot]
    with open(profile_path, encoding="utf-8") as fh:
        content = fh.read()

    pattern = re.compile(rf'(\b{option}\s*=\s*")([^"]*)(";)')
    matches = pattern.findall(content)
    if len(matches) != 1:
        raise ValueError(
            f"{option} apparaît {len(matches)} fois dans {profile_path} "
            "— attendu exactement 1, rien n'a été modifié."
        )

    previous = matches[0][1]
    if previous == name:
        return previous, name

    updated = pattern.sub(lambda m: m.group(1) + name + m.group(3), content, count=1)

    # Écriture atomique : un rebuild concurrent ne doit jamais voir un
    # fichier .nix tronqué.
    tmp = profile_path + ".theme-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(updated)
    os.replace(tmp, profile_path)
    return previous, name


def build_handler(html, token, valid_names, profile_path, favorites_path, result):
    class Handler(http.server.BaseHTTPRequestHandler):
        # Silence les logs par requête : la sortie utile est celle de `theme`.
        def log_message(self, format, *args):  # noqa: A002 (signature imposée)
            pass

        def _json(self, code, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.split("?")[0] not in ("/", "/index.html"):
                self.send_error(404)
                return
            # Relu à CHAQUE requête : un rechargement en cours de session doit
            # montrer les thèmes réellement dans le profil, pas ceux d'il y a
            # dix minutes.
            page = html.replace(
                "__THEME_CURRENT__", js_string_body(read_current(profile_path))
            ).replace(
                "__THEME_FAVORITES__", js_string_body(read_favorites(favorites_path))
            )
            body = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_json_body(self):
            length = int(self.headers.get("Content-Length", "0"))
            return json.loads(self.rfile.read(length) or b"{}")

        def do_POST(self):
            if self.path == "/favorite":
                self._handle_favorite()
                return
            if self.path != "/apply":
                self.send_error(404)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError):
                self._json(400, {"error": "requête illisible"})
                return

            # compare_digest : évite de laisser fuir la longueur du préfixe
            # correct par le temps de comparaison.
            if not secrets.compare_digest(str(payload.get("token", "")), token):
                self._json(403, {"error": "jeton invalide"})
                return

            name = str(payload.get("name", ""))
            slot = str(payload.get("slot", ""))
            # On ne fait JAMAIS confiance au nom envoyé : il doit venir du
            # manifeste, sinon on écrirait une chaîne arbitraire dans un .nix.
            if name not in valid_names:
                self._json(400, {"error": f"thème inconnu : {name}"})
                return
            if slot not in SLOTS:
                self._json(400, {"error": f"slot inconnu : {slot}"})
                return

            try:
                previous, new = apply_to_profile(profile_path, slot, name)
            except (OSError, ValueError) as err:
                self._json(500, {"error": str(err)})
                return

            # On NE coupe PAS le serveur ici : on doit pouvoir régler
            # darkTheme puis lightTheme dans la même session. Le premier
            # `previous` d'un slot est conservé pour que le récapitulatif
            # montre le point de départ réel, même après plusieurs essais.
            entry = result.setdefault(slot, {"option": SLOTS[slot], "previous": previous})
            entry["name"] = new

            if previous == new:
                message = f"{SLOTS[slot]} valait déjà « {new} »"
            else:
                message = f"{SLOTS[slot]} : « {previous} » → « {new} »"
            self._json(200, {"message": message})

        def _handle_favorite(self):
            try:
                payload = self._read_json_body()
            except (ValueError, json.JSONDecodeError):
                self._json(400, {"error": "requête illisible"})
                return

            if not secrets.compare_digest(str(payload.get("token", "")), token):
                self._json(403, {"error": "jeton invalide"})
                return

            name = str(payload.get("name", ""))
            # Même règle que pour /apply : le nom doit venir du manifeste,
            # sinon on écrirait n'importe quoi dans un fichier versionné.
            if name not in valid_names:
                self._json(400, {"error": f"thème inconnu : {name}"})
                return

            favorites = read_favorites(favorites_path)
            wanted = bool(payload.get("on"))
            already = name in favorites
            if wanted and not already:
                favorites.append(name)
            elif not wanted and already:
                favorites.remove(name)

            try:
                write_favorites(favorites_path, favorites)
            except OSError as err:
                self._json(500, {"error": str(err)})
                return

            result["favorites_touched"] = True
            self._json(200, {"favorites": sorted(set(favorites))})

        def do_DELETE(self):
            """Fin de session demandée par la page (bouton « terminer »)."""
            if self.path != "/session":
                self.send_error(404)
                return
            token_header = self.headers.get("X-Theme-Token", "")
            if not secrets.compare_digest(token_header, token):
                self._json(403, {"error": "jeton invalide"})
                return
            self._json(200, {"message": "session terminée"})
            # Laisse la réponse partir avant de couper le serveur.
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    return Handler


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 1

    gallery_path, manifest_path, profile_path, favorites_path = sys.argv[1:5]

    for path, what in ((profile_path, "le profil"), (favorites_path, "les favoris")):
        if not os.access(path, os.W_OK):
            print(
                f"theme : {path} n'est pas modifiable — impossible d'écrire {what}.",
                file=sys.stderr,
            )
            return 1

    with open(manifest_path, encoding="utf-8") as fh:
        valid_names = set(json.load(fh))
    with open(gallery_path, encoding="utf-8") as fh:
        html = fh.read()

    # Le jeton ne change pas de la session ; __THEME_CURRENT__ reste en place
    # et est substitué à chaque GET (cf. do_GET), pour qu'un rechargement
    # reflète l'état réel du profil.
    token = secrets.token_urlsafe(24)
    html = html.replace("__THEME_TOKEN__", token)

    result = {}
    handler = build_handler(
        html, token, valid_names, profile_path, favorites_path, result
    )

    # Port 0 = éphémère attribué par le noyau, et 127.0.0.1 : jamais exposé
    # hors de la machine.
    with socketserver.TCPServer(("127.0.0.1", 0), handler) as httpd:
        httpd.timeout = 1
        port = httpd.server_address[1]
        url = f"http://127.0.0.1:{port}/"
        # flush : stdout est bufferisé dès que la sortie est redirigée
        # (pipe, fichier). Sans ça l'URL n'apparaîtrait qu'à la fermeture.
        print(f"Galerie : {url}", flush=True)
        print(
            "Applique autant de thèmes que tu veux (sombre ET clair), "
            "puis « terminer » dans la page — ou Ctrl-C ici.",
            flush=True,
        )

        threading.Timer(IDLE_TIMEOUT_SECONDS, httpd.shutdown).start()

        # $THEME_BROWSER : navigateur épinglé par la commande `theme` (chemin
        # du store), pour ne pas dépendre du PATH ni de $BROWSER. Repli sur
        # webbrowser si la variable n'est pas posée.
        # Un lancement raté ne doit PAS tuer le serveur : l'URL est déjà
        # affichée, elle reste ouvrable à la main.
        browser = os.environ.get("THEME_BROWSER")
        try:
            if browser:
                subprocess.Popen(
                    [browser, url],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            else:
                webbrowser.open(url)
        except OSError as err:
            print(f"(navigateur non lancé : {err} — ouvre l'URL à la main)", flush=True)

        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()

    favorites_touched = result.pop("favorites_touched", False)
    # Ne garde que les slots réellement changés : appliquer un thème puis
    # revenir au précédent ne doit pas déclencher un rebuild pour rien.
    changed = {slot: e for slot, e in result.items() if e["previous"] != e["name"]}

    if favorites_touched:
        print(f"Favoris mis à jour : {favorites_path}", flush=True)

    if not changed:
        # Les favoris ne changent pas le système construit : pas de rebuild
        # à proposer, d'où le code 2 même s'ils ont bougé.
        print("Aucun thème changé.", flush=True)
        return 2

    print(flush=True)
    for entry in changed.values():
        print(
            f"  {entry['option']} : « {entry['previous']} » → « {entry['name']} »",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
