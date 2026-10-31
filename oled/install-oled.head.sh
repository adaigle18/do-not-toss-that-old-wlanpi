#!/bin/bash
# =============================================================================
#  install-oled.sh — Sensor status screen: physical OLED and/or virtual (web)
#  Run from your laptop, nothing to copy:
#     ssh root@IP 'bash -s' < install-oled.sh              # physical NanoHat OLED (NEO2)
#     ssh root@IP 'bash -s -- web' < install-oled.sh       # virtual screen at http://sensor:8088
#     ssh root@IP 'bash -s -- both' < install-oled.sh      # both
#  Uninstall: ssh root@IP 'systemctl disable --now oled-status; rm -rf /opt/oled-status /etc/systemd/system/oled-status.service'
#
#  Generated from oled/oled-status.py — edit that file, then rebuild with oled/build.sh
# =============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

MODE="${1:-hw}"; BUS=0; ADDR=0x3c; PORT=8088
case "$MODE" in hw|web|both) ;; *) echo "Unknown mode: $MODE (hw|web|both)"; exit 1 ;; esac
echo "==> Mode: $MODE"

if [ "$MODE" != "web" ]; then
  echo "==> I2C: overlay i2c0"
  if ! grep -qE '^overlays=.*\bi2c0\b' /boot/armbianEnv.txt 2>/dev/null; then
    if grep -q '^overlays=' /boot/armbianEnv.txt; then sed -i 's/^overlays=\(.*\)/overlays=\1 i2c0/' /boot/armbianEnv.txt
    else echo "overlays=i2c0" >> /boot/armbianEnv.txt; fi
    echo "   (added — a reboot is needed if /dev/i2c-0 doesn't exist yet)"
  fi
fi

echo "==> Packages"
dpkg --configure -a </dev/null >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv i2c-tools </dev/null >/dev/null

echo "==> Python environment (/opt/oled-status)"
mkdir -p /opt/oled-status
[ -x /opt/oled-status/.venv/bin/python ] || python3 -m venv /opt/oled-status/.venv
/opt/oled-status/.venv/bin/pip install -q --upgrade pip </dev/null
/opt/oled-status/.venv/bin/pip install -q pillow smbus2 cbor2 </dev/null
/opt/oled-status/.venv/bin/pip install -q --no-deps luma.core luma.oled </dev/null

echo "==> Display script"
cat > /opt/oled-status/oled-status.py <<'PYEOF'
