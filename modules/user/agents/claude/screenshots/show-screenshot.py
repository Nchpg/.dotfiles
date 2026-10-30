#!/usr/bin/env python3
"""Hook PostToolUse : affiche dans feh les images renvoyées par un outil."""
import base64
import json
import os
import subprocess
import sys
import time

# Le script vit dans le store Nix (lecture seule) : les captures vont dans le runtime dir.
out_dir = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "claude-screenshots")
os.makedirs(out_dir, exist_ok=True)

payload = json.load(sys.stdin)


def images(node):
    if isinstance(node, dict):
        if node.get("type") == "image":
            src = node.get("source") or node
            data = src.get("data")
            if isinstance(data, str):
                yield data, src.get("mimeType") or src.get("media_type") or "image/png"
        for v in node.values():
            yield from images(v)
    elif isinstance(node, list):
        for v in node:
            yield from images(v)


paths = []
for i, (data, mime) in enumerate(images(payload.get("tool_response"))):
    ext = "jpg" if "jpeg" in mime else mime.split("/")[-1]
    path = os.path.join(out_dir, f"{time.strftime('%H%M%S')}-{i}.{ext}")
    with open(path, "wb") as f:
        f.write(base64.b64decode(data))
    paths.append(path)

def ancestors():
    pid = os.getpid()
    while pid > 1:
        yield pid
        with open(f"/proc/{pid}/stat") as f:
            pid = int(f.read().rsplit(")", 1)[1].split()[1])


def children_cmds(pid):
    out = subprocess.run(["pgrep", "-a", "-P", str(pid)], capture_output=True, text=True).stdout
    return out


def claude_workspace():
    """Workspace sway du terminal qui affiche cette session Claude."""
    tree = json.loads(subprocess.run(["swaymsg", "-t", "get_tree"], capture_output=True, text=True).stdout)
    windows = []  # (pid, workspace)
    recency = []  # workspaces, du plus récemment focus au plus ancien

    def walk(node, ws=None):
        if node.get("type") == "workspace":
            ws = node["name"]
        if node.get("pid"):
            windows.append((node["pid"], ws))
        kids = {c["id"]: c for c in node.get("nodes", []) + node.get("floating_nodes", [])}
        for cid in node.get("focus", []):
            if cid in kids:
                walk(kids.pop(cid), ws)
        for c in kids.values():
            walk(c, ws)

    def order(node):
        if node.get("type") == "workspace":
            recency.append(node["name"])
            return
        kids = {c["id"]: c for c in node.get("nodes", [])}
        for cid in node.get("focus", []):
            if cid in kids:
                order(kids[cid])

    walk(tree)
    order(tree)

    # Session lancée directement dans un terminal : on remonte jusqu'à sa fenêtre.
    by_pid = dict(windows)
    for pid in ancestors():
        if pid in by_pid:
            return by_pid[pid]

    # Session dans herdr : le serveur n'a pas de fenêtre, on prend le client herdr
    # dont le workspace a été regardé le plus récemment.
    herdr = [ws for pid, ws in windows if "herdr" in children_cmds(pid)]
    herdr.sort(key=lambda ws: recency.index(ws) if ws in recency else len(recency))
    return herdr[0] if herdr else None


if paths:
    viewer = subprocess.Popen(
        ["feh", "--title", "claude-screenshot", "--scale-down", "--auto-zoom", *paths],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    ws = claude_workspace()
    tab = None
    if os.environ.get("HERDR_PANE_ID"):
        # Le pane a pu changer de tab depuis son lancement : on demande à herdr.
        out = subprocess.run(
            ["herdr", "pane", "get", os.environ["HERDR_PANE_ID"]], capture_output=True, text=True
        ).stdout
        tab = json.loads(out)["result"]["pane"]["tab_id"] if out else None
    if ws:
        cmd = f"[pid={viewer.pid}] move container to workspace {ws}"
        if tab:
            cmd += f", mark --add claude-shot|{tab}|{ws}|{viewer.pid}"
        # feh (XWayland) met un moment à mapper sa fenêtre.
        for _ in range(30):
            res = subprocess.run(["swaymsg", cmd], capture_output=True, text=True).stdout
            if '"success": true' in res:
                break
            time.sleep(0.1)
    if tab:
        # Le gardien cache la capture si on n'est déjà plus sur ce tab herdr.
        subprocess.Popen(
            [sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shot-watcher.py")],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
