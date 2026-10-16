#!/usr/bin/env python3
"""Sert la galerie des thèmes et applique un choix dans la config.

    server.py <galerie.html> <manifeste.json> <profil.nix> <favoris.json>

Écoute sur 127.0.0.1 avec un jeton aléatoire par lancement : sans lui, tout processus local pourrait réécrire la config.
Codes de sortie lus par `theme` : 0 appliqué, 2 fermé sans rien appliquer (Ctrl-C ou timeout), 1 erreur.
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

IDLE_TIMEOUT_SECONDS = 15 * 60

SLOTS = {"dark": "darkTheme", "light": "lightTheme"}


def js_string_body(value):
    """json.dumps(value), échappé pour un littéral JS '...' dans un <script>."""
    encoded = json.dumps(value)
    encoded = encoded.replace("\\", "\\\\").replace("'", "\\'")
    return encoded.replace("</", "<\\/")


def read_current(profile_path):
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
    try:
        with open(favorites_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    return [str(x) for x in data] if isinstance(data, list) else []


def atomic_write(path, content):
    """Écriture atomique : un rebuild concurrent ne doit pas voir un fichier tronqué."""
    tmp = path + ".theme-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, path)


def write_favorites(favorites_path, names):
    atomic_write(
        favorites_path,
        json.dumps(sorted(set(names)), indent=2, ensure_ascii=False) + "\n",
    )


def apply_to_profile(profile_path, slot, name):
    """Remplace `<slot>Theme = "...";` dans le profil ; renvoie (ancien, nouveau). ValueError si absent ou multiple."""
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
    atomic_write(profile_path, updated)
    return previous, name


def build_handler(html, token, valid_names, profile_path, favorites_path, result):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):  # noqa: A002 (signature imposée)
            pass

        def _send(self, code, body, content_type):
            self.send_response(code)
            self.send_header("Content-Type", f"{content_type}; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code, payload):
            self._send(code, json.dumps(payload).encode("utf-8"), "application/json")

        def do_GET(self):
            if self.path.split("?")[0] not in ("/", "/index.html"):
                self.send_error(404)
                return
            page = html.replace(
                "__THEME_CURRENT__", js_string_body(read_current(profile_path))
            ).replace(
                "__THEME_FAVORITES__", js_string_body(read_favorites(favorites_path))
            )
            self._send(200, page.encode("utf-8"), "text/html")

        def _auth(self, presented):
            if secrets.compare_digest(str(presented), token):
                return True
            self._json(403, {"error": "jeton invalide"})
            return False

        def _read_payload(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError):
                self._json(400, {"error": "requête illisible"})
                return None
            if not self._auth(payload.get("token", "")):
                return None
            return payload

        def _valid_name(self, payload):
            """Nom de thème du corps, ou None (400 envoyé) ; doit venir du manifeste."""
            name = str(payload.get("name", ""))
            if name in valid_names:
                return name
            self._json(400, {"error": f"thème inconnu : {name}"})
            return None

        def do_POST(self):
            if self.path == "/favorite":
                self._handle_favorite()
                return
            if self.path != "/apply":
                self.send_error(404)
                return
            payload = self._read_payload()
            if payload is None:
                return
            name = self._valid_name(payload)
            if name is None:
                return
            slot = str(payload.get("slot", ""))
            if slot not in SLOTS:
                self._json(400, {"error": f"slot inconnu : {slot}"})
                return

            try:
                previous, new = apply_to_profile(profile_path, slot, name)
            except (OSError, ValueError) as err:
                self._json(500, {"error": str(err)})
                return

            # Le premier `previous` d'un slot est conservé pour le récapitulatif.
            entry = result.setdefault(slot, {"option": SLOTS[slot], "previous": previous})
            entry["name"] = new

            if previous == new:
                message = f"{SLOTS[slot]} valait déjà « {new} »"
            else:
                message = f"{SLOTS[slot]} : « {previous} » → « {new} »"
            self._json(200, {"message": message})

        def _handle_favorite(self):
            payload = self._read_payload()
            if payload is None:
                return
            name = self._valid_name(payload)
            if name is None:
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
            if self.path != "/session":
                self.send_error(404)
                return
            if not self._auth(self.headers.get("X-Theme-Token", "")):
                return
            self._json(200, {"message": "session terminée"})
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

    token = secrets.token_urlsafe(24)
    html = html.replace("__THEME_TOKEN__", token)

    result = {}
    handler = build_handler(
        html, token, valid_names, profile_path, favorites_path, result
    )

    with socketserver.TCPServer(("127.0.0.1", 0), handler) as httpd:
        httpd.timeout = 1
        port = httpd.server_address[1]
        url = f"http://127.0.0.1:{port}/"
        # flush : stdout est bufferisé quand il est redirigé.
        print(f"Galerie : {url}", flush=True)
        print(
            "Applique autant de thèmes que tu veux (sombre ET clair), "
            "puis « terminer » dans la page — ou Ctrl-C ici.",
            flush=True,
        )

        # daemon : sinon `theme` resterait bloqué jusqu'à l'échéance.
        idle = threading.Timer(IDLE_TIMEOUT_SECONDS, httpd.shutdown)
        idle.daemon = True
        idle.start()

        # $THEME_BROWSER : navigateur épinglé par `theme` ; un lancement raté ne tue pas le serveur.
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
        finally:
            idle.cancel()

    favorites_touched = result.pop("favorites_touched", False)
    changed = {slot: e for slot, e in result.items() if e["previous"] != e["name"]}

    if favorites_touched:
        print(f"Favoris mis à jour : {favorites_path}", flush=True)

    if not changed:
        # Les favoris ne changent pas le système : code 2 même s'ils ont bougé.
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
