#!/bin/bash
# =============================================================================
#  backup-sensor.sh — Back up a sensor's configuration to your laptop.
#  Usage:  ./backup-sensor.sh root@192.168.1.50
#  Output: backups/<sensor>_<date>.tar.gz  (includes inventory.txt)
#
#  Does NOT include the Tailscale or Orb identity: a restored sensor must
#  register as a new device. Contains the Wi-Fi password (netplan), so the
#  archive is created with mode 600.
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
T="${1:?Usage: ./backup-sensor.sh root@IP}"
mkdir -p "$DIR/backups"; chmod 700 "$DIR/backups"
NAME=$(ssh -o BatchMode=yes "$T" hostname)
OUT="$DIR/backups/${NAME}_$(date +%Y%m%d-%H%M).tar.gz"

ssh "$T" 'bash -s' > "$OUT" <<'REMOTE'
TMP=$(mktemp -d)
{
  echo "# Inventory $(hostname) — $(date)"
  echo; echo "## Board";     tr -d '\0' </proc/device-tree/model 2>/dev/null; echo
  echo; echo "## OS";        . /etc/os-release; echo "$PRETTY_NAME — kernel $(uname -r)"
  echo; echo "## Packages";  dpkg-query -W -f='${Package} ${Version}\n' orb tailscale iw iperf3 tcpdump 2>/dev/null
  echo; echo "## USB";       lsusb
  echo; echo "## Network";   ip -br addr; ip route
  echo; echo "## Wi-Fi";     iw dev wlan0 link 2>/dev/null; iw reg get 2>/dev/null | head -3
  echo; echo "## Services";  for s in orb orb-update.timer tailscaled oled-status; do echo "$s: $(systemctl is-enabled $s 2>/dev/null)/$(systemctl is-active $s 2>/dev/null)"; done
} > "$TMP/inventory.txt" 2>&1
tar -czf - -C / --ignore-failed-read \
  etc/hostname etc/hosts etc/netplan \
  etc/systemd/network/10-wifi-usb.link \
  etc/udev/rules.d/70-wifi-powersave.rules \
  etc/sysctl.d/90-nanopi-recycled.conf \
  boot/armbianEnv.txt \
  etc/apt/sources.list.d \
  opt/oled-status/oled-status.py etc/systemd/system/oled-status.service \
  etc/systemd/system/orb.service.d \
  -C "$TMP" inventory.txt 2>/dev/null
rm -rf "$TMP"
REMOTE
chmod 600 "$OUT"
echo "✔ Backup: $OUT"
tar -tzf "$OUT" | sed 's/^/   /'
