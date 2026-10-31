#!/bin/bash
# Install the orb-sensors MCP server on macOS.
# Usage: cd do-not-toss-that-old-wlanpi && bash install-mac.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

PY=$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)
echo "==> Python: $PY ($($PY --version))"

$PY -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q "mcp[cli]"
.venv/bin/python -c "import server; print('==> server.py OK')"

[ -f sensors.json ] || { cp sensors.example.json sensors.json; echo "==> Created sensors.json from the example — edit it"; }

CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
echo
echo "==> Add this under \"mcpServers\" in:"
echo "    $CFG"
cat <<JSON

    "orb-sensors": {
      "command": "$DIR/.venv/bin/python",
      "args": ["$DIR/server.py"]
    }

JSON
echo "Then quit Claude Desktop completely (Cmd+Q) and reopen it."
