#!/usr/bin/env python3
"""garmin-mcp en lecture seule, derrière un jeton tiré au premier démarrage.

Le jeton est celui de l'en-tête `Authorization: Bearer` que garmin-mcp vérifie lui-même. nginx le lit aussi
dans le chemin (/<jeton>/mcp), pour les clients qui ne savent pas poser d'en-tête (claude.ai).
"""

import os
import secrets
import sys
from pathlib import Path

from garmin_mcp import main
from garmin_mcp.tool_annotations import READ_ONLY_TOOLS

token_file = Path(os.environ["STATE_DIRECTORY"]) / "token"
if not token_file.exists():
    fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(secrets.token_urlsafe(32))

token = token_file.read_text().strip()
# Fichier vide (arrêt pendant l'écriture) ou modifié à la main : ne jamais servir sans vrai jeton.
if len(token) < 32:
    sys.exit(f"{token_file} : jeton absent ou trop court, supprimer le fichier pour en tirer un autre.")

os.environ["GARMIN_MCP_HTTP_TOKEN"] = token
# Sans profil, la liste d'outils permis est exclusive. Elle est tenue en amont : un outil ajouté plus tard
# n'apparaît que s'il y est classé en lecture.
os.environ.pop("GARMIN_TOOL_PROFILE", None)
os.environ["GARMIN_ENABLED_TOOLS"] = ",".join(sorted(READ_ONLY_TOOLS))

main()
