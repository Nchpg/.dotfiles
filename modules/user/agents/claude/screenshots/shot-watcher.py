#!/usr/bin/env python3
"""Montre les captures de Claude seulement quand le tab herdr qui les a prises est actif.

Chaque fenêtre feh porte une marque sway « claude-shot|<tab herdr>|<workspace sway>|<pid> ».
Un seul gardien tourne à la fois (verrou) et il s'arrête quand plus aucune capture n'est ouverte.
"""
import fcntl
import json
import os
import socket
import subprocess
import sys

lock_dir = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "claude-screenshots")
os.makedirs(lock_dir, exist_ok=True)
lock = open(os.path.join(lock_dir, "shot-watcher.lock"), "w")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)


def sway(cmd):
    return subprocess.run(["swaymsg", cmd], capture_output=True, text=True).stdout


def shots():
    """(con_id, tab, workspace cible, caché ?) pour chaque capture ouverte."""
    found = []

    def walk(node, ws=None):
        if node.get("type") == "workspace":
            ws = node["name"]
        for mark in node.get("marks", []):
            if mark.startswith("claude-shot|"):
                _, tab, target, _ = mark.split("|")
                found.append((node["id"], tab, target, ws == "__i3_scratch"))
        for c in node.get("nodes", []) + node.get("floating_nodes", []):
            walk(c, ws)

    tree = subprocess.run(["swaymsg", "-t", "get_tree"], capture_output=True, text=True).stdout
    walk(json.loads(tree))
    return found


def focused_tab():
    out = subprocess.run(["herdr", "workspace", "list"], capture_output=True, text=True).stdout
    for ws in json.loads(out)["result"]["workspaces"]:
        if ws["focused"]:
            return ws["active_tab_id"]


def sync():
    current = shots()
    if not current:
        sys.exit(0)
    active = focused_tab()
    for con_id, tab, target, hidden in current:
        if tab == active and hidden:
            sway(f"[con_id={con_id}] move container to workspace {target}")
        elif tab != active and not hidden:
            sway(f"[con_id={con_id}] move scratchpad")


sync()

s = socket.socket(socket.AF_UNIX)
s.connect(os.environ.get("HERDR_SOCKET_PATH", os.path.expanduser("~/.config/herdr/herdr.sock")))
req = {
    "id": "shots",
    "method": "events.subscribe",
    "params": {"subscriptions": [{"type": "tab.focused"}, {"type": "workspace.focused"}]},
}
s.sendall((json.dumps(req) + "\n").encode())
# Réveil périodique pour s'arrêter quand toutes les captures ont été fermées.
s.settimeout(30)

buf = b""
while True:
    try:
        chunk = s.recv(65536)
    except socket.timeout:
        sync()
        continue
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if "event" in json.loads(line):
            sync()
