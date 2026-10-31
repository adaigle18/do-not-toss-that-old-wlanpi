#!/bin/bash
# =============================================================================
#  NanoPi (recycled) + Orb Sensor — remote 802.11 frame capture from your laptop
#  v0.4
#
#  The sensor switches its Wi-Fi adapter to monitor mode, streams frames live
#  to Wireshark on your laptop (nothing is written to the microSD), then goes
#  back to Orb client mode AUTOMATICALLY when you stop.
#
#  Usage:
#    ./nanopi-recycled.sh capture root@192.168.1.50 -b 5 -c 157 [-w 20] [options]
#    ./nanopi-recycled.sh status  root@192.168.1.50
#    ./nanopi-recycled.sh restore root@192.168.1.50      # force back to Orb mode
#
#  Capture options:
#    -b BAND     2.4 | 5 | 6                          (default 5)
#    -c CHANNEL  primary channel number               (default 36)
#    -w WIDTH    20 | 40 | 80 | 160 MHz               (default 20)
#    -d SEC      duration; 0 = until Wireshark closes or Ctrl+C (default 0)
#    -o FILE     save to a .pcap instead of opening Wireshark
#    -s BYTES    truncate each frame (e.g. 256: headers only, for privacy)
#    -f FILTER   tcpdump filter (e.g. "type mgt", "wlan addr2 aa:bb:cc:dd:ee:ff")
#    -i IFACE    sensor Wi-Fi interface               (default wlan0)
#    -m SEC      safety net: force Orb mode back after SEC (default 1800)
#
#  Examples:
#    ./nanopi-recycled.sh capture root@192.168.1.50 -b 5 -c 157
#    ./nanopi-recycled.sh capture root@192.168.1.50 -b 5 -c 157 -f "type mgt" -d 60 -o beacons.pcap
# =============================================================================
set -u
WIRESHARK="${WIRESHARK:-/Applications/Wireshark.app/Contents/MacOS/Wireshark}"
[ -x "$WIRESHARK" ] || WIRESHARK="$(command -v wireshark 2>/dev/null || echo "$WIRESHARK")"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=12)

usage() { sed -n '2,29p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

CMD="${1:-}"; TARGET="${2:-}"
[ -z "$CMD" ] || [ -z "$TARGET" ] && usage
shift 2

BAND=5; CH=36; WIDTH=20; DUR=0; OUT=""; SNAP=0; FILTER=""; IFACE=wlan0; MAX=1800
while getopts "b:c:w:d:o:s:f:i:m:" o; do
  case $o in
    b) BAND=$OPTARG ;; c) CH=$OPTARG ;; w) WIDTH=$OPTARG ;; d) DUR=$OPTARG ;;
    o) OUT=$OPTARG ;; s) SNAP=$OPTARG ;; f) FILTER=$OPTARG ;; i) IFACE=$OPTARG ;; m) MAX=$OPTARG ;;
    *) usage ;;
  esac
done

case "$IFACE" in *[!A-Za-z0-9_.-]*|"") echo "Invalid interface: $IFACE"; exit 1 ;; esac
for n in "$CH" "$WIDTH" "$DUR" "$SNAP" "$MAX"; do
  case "$n" in ''|*[!0-9]*) echo "Invalid number: $n"; exit 1 ;; esac
done

RESTORE="ip link set $IFACE down 2>/dev/null; iw dev $IFACE set type managed 2>/dev/null; ip link set $IFACE up 2>/dev/null; systemctl start netplan-wpa-$IFACE.service 2>/dev/null; networkctl reconfigure $IFACE 2>/dev/null; rm -f /run/nanopi-recycled.state"

# --------------------------------------------------------------------------- #
# Frequency / center frequency math
# --------------------------------------------------------------------------- #
freq_of() {  # band channel -> MHz
  case "$1" in
    2.4|2) if [ "$2" -eq 14 ]; then echo 2484; else echo $((2407 + 5 * $2)); fi ;;
    5)     echo $((5000 + 5 * $2)) ;;
    6)     echo $((5950 + 5 * $2)) ;;
    *)     echo 0 ;;
  esac
}
center_ch() {  # band channel width -> center channel
  local b=$1 c=$2 w=$3 list="" span
  [ "$w" -le 20 ] && { echo "$c"; return; }
  case "$b" in
    2.4|2) [ "$w" -eq 40 ] || { echo "ERR"; return; }
           if [ "$c" -le 7 ]; then echo $((c + 2)); else echo $((c - 2)); fi; return ;;
    5) case "$w" in
         40)  list="38 46 54 62 102 110 118 126 134 142 151 159 167 175" ;;
         80)  list="42 58 106 122 138 155 171" ;;
         160) list="50 114 163" ;;
       esac ;;
    6) local k=0 base step
       case "$w" in 40) base=3; step=8 ;; 80) base=7; step=16 ;; 160) base=15; step=32 ;; *) echo ERR; return ;; esac
       while [ $((base + k * step)) -le 233 ]; do list="$list $((base + k * step))"; k=$((k + 1)); done ;;
  esac
  span=$(( (w / 10) - 2 ))
  for x in $list; do
    d=$((c - x)); [ $d -lt 0 ] && d=$((-d))
    [ $d -le $span ] && { echo "$x"; return; }
  done
  echo "ERR"
}

# --------------------------------------------------------------------------- #
case "$CMD" in
status)
  ssh "${SSH_OPTS[@]}" "$TARGET" "echo \"Mode    : \$(iw dev $IFACE info 2>/dev/null | awk '/type/{print \$2}')\";
    iw dev $IFACE info 2>/dev/null | awk '/channel/{print \"Channel : \" \$0}';
    echo \"Client  : \$(systemctl is-active netplan-wpa-$IFACE.service)\";
    echo \"Orb     : \$(systemctl is-active orb)\";
    [ -f /run/nanopi-recycled.state ] && echo \"Capturing since: \$(cat /run/nanopi-recycled.state)\" || true"
  exit $? ;;
restore)
  ssh "${SSH_OPTS[@]}" "$TARGET" "pkill -f '[t]cpdump -i $IFACE' 2>/dev/null; pkill -f '[n]anopi-recycled-watchdog' 2>/dev/null; $RESTORE; sleep 6; iw dev $IFACE link | grep -E 'SSID|freq' || echo 'Not associated yet (give it a few seconds)'"
  exit $? ;;
capture) ;;
*) usage ;;
esac

F=$(freq_of "$BAND" "$CH")
CC=$(center_ch "$BAND" "$CH" "$WIDTH")
[ "$F" -eq 0 ] || [ "$CC" = "ERR" ] && { echo "Invalid band/channel/width: $BAND GHz, channel $CH, $WIDTH MHz"; exit 1; }
CF=$(freq_of "$BAND" "$CC")
# Width keyword for "iw set freq" (iw computes the center itself)
case "$WIDTH" in
  20)  WKW="" ;;
  40)  if [ "$CC" -gt "$CH" ]; then WKW="HT40+"; else WKW="HT40-"; fi ;;
  80)  WKW="80MHz" ;;
  160) WKW="160MHz" ;;
  *)   echo "Unsupported width: $WIDTH"; exit 1 ;;
esac

if [ -z "$OUT" ] && [ ! -x "$WIRESHARK" ]; then
  echo "Wireshark not found ($WIRESHARK). Install it, set WIRESHARK=/path, or use -o capture.pcap"; exit 1
fi

# -Q in: only frames the radio RECEIVES (packets the host sends on a monitor
# interface have no radiotap header and show up as "Malformed" in Wireshark)
TCPD="tcpdump -i $IFACE -Q in -U -w -"
[ "$SNAP" -gt 0 ] && TCPD="$TCPD -s $SNAP"
[ "$DUR" -gt 0 ] && TCPD="timeout $DUR $TCPD"
QFILTER=""
[ -n "$FILTER" ] && QFILTER=$(printf '%q' "$FILTER")

# Script run on the sensor. Every message goes to stderr: stdout = frames.
REMOTE=$(cat <<EOF
set -u
log() { echo "  \$*" >&2; }
[ "\$(id -u)" -eq 0 ] || { log "✘ Root login required"; exit 1; }
command -v tcpdump >/dev/null || { log "✘ tcpdump missing: apt install tcpdump"; exit 1; }
iw dev $IFACE info >/dev/null 2>&1 || { log "✘ Interface $IFACE not found"; exit 1; }

# Safety: we need another (wired) link to keep the session alive during capture
ALT=\$(ip -4 -o addr show up 2>/dev/null | awk '{print \$2}' | grep -vE "^(lo|$IFACE|tailscale0)\$" | head -1)
if [ -z "\$ALT" ] || ! ip link show "\$ALT" | grep -q "LOWER_UP"; then
  log "✘ No active wired link: switching $IFACE to monitor would cut this session."
  log "  Plug in the sensor's Ethernet and try again."; exit 1
fi
log "✔ Session kept alive over \$ALT during capture"

# ARP flux protection: only the interface owning an address answers ARP,
# then announce the wired MAC so peers update their cache right away
sysctl -qw net.ipv4.conf.all.arp_ignore=1 net.ipv4.conf.all.arp_announce=2 2>/dev/null
ALTIP=\$(ip -4 -o addr show "\$ALT" | awk '{print \$4}' | cut -d/ -f1 | head -1)
command -v arping >/dev/null && arping -q -U -c 3 -I "\$ALT" "\$ALTIP" >/dev/null 2>&1 &

restore() {
  trap - EXIT HUP INT TERM PIPE
  pkill -f '[n]anopi-recycled-watchdog' 2>/dev/null
  $RESTORE
  log "↺ $IFACE back in client mode — Orb is measuring Wi-Fi again"
}

# Safety net: force the restore even if the connection is lost
nohup bash -c ": nanopi-recycled-watchdog; sleep $MAX; $RESTORE" >/dev/null 2>&1 &
date '+%H:%M:%S' > /run/nanopi-recycled.state
trap restore EXIT HUP INT TERM PIPE

systemctl stop netplan-wpa-$IFACE.service 2>/dev/null
# mt76 bug (mt7921u/mt7925u): once associated, the radio ignores channel changes in
# monitor mode. Reloading the driver lets it retune before any association.
DRV=\$(basename "\$(readlink /sys/class/net/$IFACE/device/driver 2>/dev/null)")
case "\$DRV" in mt79*)
  log "↻ Reloading \$DRV (mt76 bug: otherwise the radio stays on the old channel)"
  ip link set $IFACE down; modprobe -r \$DRV; sleep 2; modprobe \$DRV
  for i in \$(seq 1 20); do ip link show $IFACE >/dev/null 2>&1 && break; sleep 0.5; done
  systemctl stop netplan-wpa-$IFACE.service 2>/dev/null; pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null ;;
esac
ip link set $IFACE down
iw dev $IFACE set type monitor || { log "✘ Monitor mode refused by the driver"; exit 1; }
ip addr flush dev $IFACE 2>/dev/null
ip link set $IFACE up
ip addr flush dev $IFACE 2>/dev/null
if ! iw dev $IFACE set freq $F $WKW 2>/dev/null; then
  iw dev $IFACE set freq $F 2>/dev/null || { log "✘ Frequency $F MHz refused (regdomain, DFS or driver)"; exit 1; }
  [ -n "$WKW" ] && log "⚠ $WIDTH MHz width refused by the driver, capturing at 20 MHz"
fi
log "  Radio: \$(iw dev $IFACE info | awk '/channel/{\$1=\$1; print}')"
log "● Capturing: $BAND GHz · channel $CH · $WIDTH MHz (control $F MHz, center $CF MHz)"
log "● Orb keeps measuring over Ethernet during capture; automatic return to Orb mode at the end"
$TCPD $QFILTER
EOF
)

echo "NanoPi (recycled) + Orb Sensor — $TARGET"

cleanup() {
  # back to Orb mode, retrying if the sensor is briefly unreachable
  for i in 1 2 3 4 5 6; do
    ssh "${SSH_OPTS[@]}" -o ServerAliveCountMax=3 "$TARGET" \
      "[ -f /run/nanopi-recycled.state ] && { pkill -f '[t]cpdump -i $IFACE'; sleep 1; $RESTORE; } ; true" >/dev/null 2>&1 && return
    sleep 10
  done
  echo "  ⚠ Sensor unreachable: run \"$0 restore $TARGET\" (safety net: automatic restore after $MAX s)"
}
trap cleanup EXIT INT TERM

if [ -n "$OUT" ]; then
  echo "  Saving to $OUT (Ctrl+C to stop)"
  ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s" <<<"$REMOTE" > "$OUT"
  echo "  ✔ $(du -h "$OUT" | cut -f1) saved to $OUT"
else
  echo "  Wireshark is opening; close it (or Ctrl+C here) to stop"
  ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s" <<<"$REMOTE" | "$WIRESHARK" -k -i - >/dev/null 2>&1
fi
