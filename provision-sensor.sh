#!/bin/bash
# =============================================================================
#  provision-sensor.sh — Turn a freshly flashed Armbian NanoPi into a complete
#  Orb sensor (Orb, Wi-Fi, Tailscale, status screen). Run it FROM YOUR LAPTOP.
#
#  Usage:
#     ./provision-sensor.sh root@192.168.1.50 sensor-neo2-01
#     ./provision-sensor.sh root@192.168.1.50 sensor-neo2-01 --oled   # force the physical OLED
#
#  Prerequisites: Armbian first-boot wizard done, root SSH key access (ssh-copy-id root@IP).
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET="${1:-}"; NAME="${2:-}"; OLED="${3:-auto}"
if [ -z "$TARGET" ] || [ -z "$NAME" ]; then sed -n '6,11p' "$0"; exit 1; fi
case "$TARGET" in root@*) ;; *) echo "Use root@IP (the script configures the system)."; exit 1 ;; esac
HOST="${TARGET#root@}"

echo "▶ Checking SSH access to $TARGET"
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" true 2>/dev/null; then
  echo "✘ Key-based access failed. Run first: ssh-copy-id $TARGET"; exit 1
fi
MODEL=$(ssh "$TARGET" "tr -d '\0' 2>/dev/null </proc/device-tree/model")
echo "  Board: ${MODEL:-unknown}"

echo
read -r -p "Wi-Fi SSID (empty = no Wi-Fi): " SSID
[ -z "$SSID" ] && { read -r -p "  No Wi-Fi will be configured. Confirm? [y/N] " R; case "$R" in y|Y) ;; *) read -r -p "Wi-Fi SSID: " SSID ;; esac; }
PSK=""; BAND="5GHz"
if [ -n "$SSID" ]; then
  read -r -s -p "Wi-Fi password: " PSK; echo
  read -r -p "Band [5GHz/2.4GHz/auto] (default 5GHz): " B; BAND="${B:-5GHz}"
fi
read -r -p "Tailscale auth key (empty = log in with a browser link): " TSKEY

SSID_B64=$(printf '%s' "$SSID" | base64 | tr -d '\n')
PSK_B64=$(printf '%s' "$PSK" | base64 | tr -d '\n')

echo
echo "▶ Configuring the sensor"
ssh "$TARGET" 'cat > /tmp/sensor-setup.sh && chmod 700 /tmp/sensor-setup.sh' < "$DIR/sensor-setup.sh"
ARGS="-n $NAME -s '$SSID_B64' -k '$PSK_B64' -b $BAND"
[ -n "$TSKEY" ] && ARGS="$ARGS -t $TSKEY"
ssh -t "$TARGET" "bash /tmp/sensor-setup.sh $ARGS; rm -f /tmp/sensor-setup.sh"

# Status screen: physical + virtual on NEO2 (original WLAN Pi), virtual elsewhere
if [ -f "$DIR/install-oled.sh" ]; then
  if [ "$OLED" = "--oled" ] || echo "$MODEL" | grep -qiE "neo ?2"; then OMODE=both; else OMODE=web; fi
  echo; echo "▶ Status screen ($OMODE)"
  ssh "$TARGET" "bash -s -- $OMODE" < "$DIR/install-oled.sh" || echo "  ⚠ Screen: see messages above"
fi

# Add / update the sensor in sensors.json (MCP server, dashboard, diag.sh)
python3 - "$DIR/sensors.json" "$NAME" "$HOST" <<'PY'
import json, sys, pathlib
p, name, host = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
d = json.loads(p.read_text()) if p.exists() else {"sensors": {}}
s = d["sensors"].setdefault(name, {"site": "", "wifi_iface": "auto"})
s.update(host=host, user="root")
p.write_text(json.dumps(d, indent=2, ensure_ascii=False))
print(f"\n✔ {name} ({host}) added to sensors.json")
PY

echo "✔ Done. Test: ./diag.sh $TARGET -- -n"
