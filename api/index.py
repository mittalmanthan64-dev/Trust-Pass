"""Vercel request-based API function. Local launchers use backend.server directly."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.server import Handler, init_db

init_db()

# Vercel's Python runtime discovers the lowercase handler class.
handler = Handler
