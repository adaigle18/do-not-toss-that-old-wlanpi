#!/bin/bash
# Run ONCE on a sensor with a NON-root user, if you don't want to use root over SSH:
#   bash prepare-sensor.sh
# Installs the diagnostic tools and gives that user:
#   - read access to the systemd journal (systemd-journal group)
#   - passwordless sudo for "iw" ONLY (needed for Wi-Fi scans)
# No agent or service is installed.
set -euo pipefail

U="${SUDO_USER:-$USER}"
if [ "$U" = "root" ]; then
  echo "Run this with your regular user, not root." >&2
  exit 1
fi

echo "==> Tools: iw, iperf3, tracepath, tcpdump"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iw iperf3 iputils-tracepath tcpdump

echo "==> Journal access for $U"
sudo usermod -aG systemd-journal "$U"

echo "==> Passwordless sudo for iw only"
IW=$(command -v iw)
TMP=$(mktemp)
echo "$U ALL=(root) NOPASSWD: $IW" > "$TMP"
sudo visudo -cf "$TMP" >/dev/null
sudo install -m 0440 -o root -g root "$TMP" /etc/sudoers.d/orb-mcp
rm -f "$TMP"

echo
echo "Done. Log out and back in for the systemd-journal group to apply."
