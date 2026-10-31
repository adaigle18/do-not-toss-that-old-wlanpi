#!/bin/bash
# Start the NanoPi (recycled) + Orb Sensor dashboard and open it in your browser.
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${DASH_PORT:-8787}"
PY="$DIR/.venv/bin/python"; [ -x "$PY" ] || PY="$(command -v python3)"
if ! curl -fs "http://127.0.0.1:$PORT/api/sensors" >/dev/null 2>&1; then
  nohup "$PY" "$DIR/dashboard.py" > "$DIR/dashboard.log" 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; curl -fs "http://127.0.0.1:$PORT/api/sensors" >/dev/null 2>&1 && break; done
fi
open "http://127.0.0.1:$PORT" 2>/dev/null || xdg-open "http://127.0.0.1:$PORT" 2>/dev/null
echo "Dashboard: http://127.0.0.1:$PORT   (stop: pkill -f dashboard.py)"
