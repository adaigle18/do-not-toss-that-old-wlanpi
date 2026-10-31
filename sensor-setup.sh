#!/bin/bash
# =============================================================================
#  sensor-setup.sh — Configure an Orb sensor on Armbian. Runs AS ROOT on the
#  sensor; launched by provision-sensor.sh from your laptop. Idempotent.
#
#  Arguments: -n hostname  -s SSID_b64  -k PSK_b64  -b band (5GHz|2.4GHz|auto)
#             -t tailscale_authkey (optional)  -c country (default CA)
# =============================================================================
set -uo pipefail
exec </dev/null   # no command may read stdin

NAME=""; SSID=""; PSK=""; BAND="5GHz"; TSKEY=""; COUNTRY="CA"
while getopts "n:s:k:b:t:c:" o; do
  case $o in
    n) NAME=$OPTARG ;; s) SSID=$(echo "$OPTARG" | base64 -d) ;; k) PSK=$(echo "$OPTARG" | base64 -d) ;;
    b) BAND=$OPTARG ;; t) TSKEY=$OPTARG ;; c) COUNTRY=$OPTARG ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "Must run as root"; exit 1; }
[ -n "$NAME" ] || { echo "Missing hostname (-n)"; exit 1; }

ok()   { printf '  \e[32m✔\e[0m %s\n' "$1"; }
step() { printf '\n\e[1m==> %s\e[0m\n' "$1"; }
fail() { printf '  \e[31m✘\e[0m %s\n' "$1"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
step "Hostname: $NAME"
OLD=$(hostname)
echo "$NAME" > /etc/hostname
sed -i "s/\b$OLD\b/$NAME/g" /etc/hosts
grep -q "\b$NAME\b" /etc/hosts || echo "127.0.1.1 $NAME" >> /etc/hosts
hostname "$NAME"
ok "hostname = $(hostname)"

# -----------------------------------------------------------------------------
step "Base packages"
# Repair an interrupted install (e.g. forced reboot during an upgrade)
dpkg --configure -a >/dev/null 2>&1 || true
apt-get -f install -y -qq >/dev/null 2>&1 || true
apt-get update -qq || fail "apt-get update failed"
apt-get install -y -qq iw iperf3 iputils-tracepath iputils-arping tcpdump wpasupplicant i2c-tools curl ca-certificates gnupg >/dev/null \
  || fail "package install failed — run: dpkg --configure -a"
ok "iw, iperf3, tracepath, arping, tcpdump, wpasupplicant, i2c-tools"

# -----------------------------------------------------------------------------
step "Orb"
if ! dpkg -s orb >/dev/null 2>&1; then
  curl -fsSL https://pkgs.orb.net/stable/debian/orbforge.noarmor.gpg -o /usr/share/keyrings/orbforge-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/orbforge-keyring.gpg] https://pkgs.orb.net/stable/debian orb main" \
    > /etc/apt/sources.list.d/orb.list
  apt-get update -qq && apt-get install -y -qq orb >/dev/null
fi
# Let Orb scan nearby APs (otherwise: "cap_net_admin capability not found")
mkdir -p /etc/systemd/system/orb.service.d
printf "[Service]\nAmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW\n" > /etc/systemd/system/orb.service.d/caps.conf
systemctl daemon-reload
systemctl enable --now orb >/dev/null 2>&1
systemctl enable --now orb-update.timer >/dev/null 2>&1
ok "orb $(dpkg-query -W -f='${Version}' orb 2>/dev/null) · service $(systemctl is-active orb) · auto-update $(systemctl is-enabled orb-update.timer 2>/dev/null)"

# -----------------------------------------------------------------------------
step "Wi-Fi: stable name wlan0 for any USB adapter"
cat > /etc/systemd/network/10-wifi-usb.link <<'EOF'
[Match]
Type=wlan

[Link]
Name=wlan0
EOF
CUR=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
if [ -n "$CUR" ] && [ "$CUR" != "wlan0" ]; then
  ip link set "$CUR" down && ip link set "$CUR" name wlan0 && ok "$CUR renamed to wlan0"
elif [ -z "$CUR" ]; then
  echo "  ⚠ No Wi-Fi adapter detected yet (config applies when you plug one in)"
fi
ok ".link rule installed"

step "Wi-Fi: power save off"
echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan0", RUN+="/usr/sbin/iw dev wlan0 set power_save off"' \
  > /etc/udev/rules.d/70-wifi-powersave.rules
iw dev wlan0 set power_save off 2>/dev/null && ok "power_save off" || true

step "Network: two interfaces on the same subnet (ARP flux protection)"
printf "net.ipv4.conf.all.arp_ignore=1\nnet.ipv4.conf.all.arp_announce=2\n" > /etc/sysctl.d/90-nanopi-recycled.conf
sysctl -q -p /etc/sysctl.d/90-nanopi-recycled.conf && ok "arp_ignore=1, arp_announce=2"

step "Regulatory domain: $COUNTRY"
iw reg set "$COUNTRY" 2>/dev/null || true
if [ -f /boot/armbianEnv.txt ] && ! grep -q "ieee80211_regdom" /boot/armbianEnv.txt; then
  if grep -q "^extraargs=" /boot/armbianEnv.txt; then
    sed -i "s/^extraargs=\(.*\)/extraargs=\1 cfg80211.ieee80211_regdom=$COUNTRY/" /boot/armbianEnv.txt
  else
    echo "extraargs=cfg80211.ieee80211_regdom=$COUNTRY" >> /boot/armbianEnv.txt
  fi
fi
ok "regdom $COUNTRY (persistent across reboots)"

# -----------------------------------------------------------------------------
if [ -n "$SSID" ]; then
  step "Wi-Fi: joining \"$SSID\" (band $BAND, route metric 50)"
  if [ -d /etc/netplan ]; then
    esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
    BANDLINE=""; [ "$BAND" != "auto" ] && BANDLINE="          band: $BAND"
    {
      echo "network:"
      echo "  version: 2"
      echo "  renderer: networkd"
      echo "  wifis:"
      echo "    wlan0:"
      echo "      dhcp4: true"
      echo "      dhcp6: true"
      echo "      dhcp4-overrides:"
      echo "        route-metric: 50"
      echo "      dhcp6-overrides:"
      echo "        route-metric: 50"
      echo "      access-points:"
      echo "        \"$(esc "$SSID")\":"
      echo "          password: \"$(esc "$PSK")\""
      [ -n "$BANDLINE" ] && echo "$BANDLINE"
    } > /etc/netplan/30-wifi.yaml
    chmod 600 /etc/netplan/30-wifi.yaml
    netplan generate && netplan apply
    sleep 12
    if iw dev wlan0 link 2>/dev/null | grep -q "SSID"; then
      ok "$(iw dev wlan0 link | sed -n 's/^\s*SSID: //p') · $(iw dev wlan0 link | awk '/freq:/{print $2" MHz"}') · $(iw dev wlan0 link | awk '/signal:/{print $2" dBm"}')"
    else
      echo "  ⚠ Not associated yet — check with: iw dev wlan0 link"
    fi
  else
    echo "  ⚠ No /etc/netplan: this system doesn't use netplan, Wi-Fi not configured"
  fi
else
  echo -e "\n(Wi-Fi skipped: no SSID given)"
fi

# -----------------------------------------------------------------------------
step "Tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
  command -v tailscale >/dev/null || fail "Tailscale install failed"
fi
systemctl enable --now tailscaled >/dev/null 2>&1
if tailscale status >/dev/null 2>&1; then
  ok "already connected: $(tailscale ip -4 2>/dev/null)"
elif [ -n "$TSKEY" ]; then
  tailscale up --auth-key="$TSKEY" --hostname="$NAME" && ok "connected: $(tailscale ip -4)"
else
  echo "  Open the link below to authorize this sensor:"
  tailscale up --hostname="$NAME" && ok "connected: $(tailscale ip -4)"
fi

# -----------------------------------------------------------------------------
step "Restarting Orb (picks up the Wi-Fi route)"
systemctl restart orb && ok "orb $(systemctl is-active orb)"

step "Summary"
ip -br addr | grep -vE "^lo" | sed 's/^/  /'
ip route show default | sed 's/^/  /'
echo
echo "Done. Link the sensor to your account in the Orb app if it isn't already."
echo "A reboot applies the regulatory domain to the kernel: sync; reboot"
