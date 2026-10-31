#!/bin/bash
# =============================================================================
#  sensor-diag.sh — Full health check of an Orb / NanoPi sensor
#
#  On the sensor:
#     bash sensor-diag.sh [-t target] [-p iperf3_server] [-d seconds] [-n] [-o file]
#
#  From your laptop (nothing copied to the sensor) — or use ./diag.sh:
#     ssh root@sensor-01 'bash -s' < sensor-diag.sh
#     ssh root@sensor-01 'bash -s -- -t 8.8.8.8 -p 100.64.0.5' < sensor-diag.sh
#
#  Options:
#     -t TARGET  ping / traceroute target          (default: gateway + 1.1.1.1)
#     -p SERVER  iperf3 server (upload + download) (default: skipped)
#     -d SEC     iperf3 duration in seconds        (default: 10)
#     -i IFACE   Wi-Fi interface                   (default: auto-detect)
#     -n         skip the Wi-Fi scan
#     -o FILE    also save the report to a file
# =============================================================================
set -u

TARGET=""; IPERF=""; DUR=10; IFACE=""; NOSCAN=0; OUT=""
while getopts "t:p:d:i:no:h" o; do
  case $o in
    t) TARGET=$OPTARG ;; p) IPERF=$OPTARG ;; d) DUR=$OPTARG ;;
    i) IFACE=$OPTARG ;; n) NOSCAN=1 ;; o) OUT=$OPTARG ;;
    *) echo "Options: -t target  -p iperf3_server  -d seconds  -i iface  -n (no scan)  -o file"; exit 0 ;;
  esac
done

if [ -n "$OUT" ]; then exec > >(tee "$OUT") 2>&1; fi

# --- Formatting -------------------------------------------------------------
if [ -t 1 ]; then B=$'\e[1m'; C=$'\e[36m'; Y=$'\e[33m'; R=$'\e[31m'; G=$'\e[32m'; N=$'\e[0m'
else B=""; C=""; Y=""; R=""; G=""; N=""; fi
section() { printf '\n%s══ %s %s\n' "$C$B" "$1" "$N"; }
kv()      { printf '  %-18s %s\n' "$1" "$2"; }
warn()    { printf '  %s⚠ %s%s\n' "$Y" "$1" "$N"; }
have()    { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo -n"; fi

freq2ch() {  # frequency MHz -> channel
  local f=${1%.*}
  if   [ "$f" -eq 2484 ]; then echo 14
  elif [ "$f" -ge 2412 ] && [ "$f" -le 2472 ]; then echo $(( (f-2407)/5 ))
  elif [ "$f" -ge 5150 ] && [ "$f" -le 5895 ]; then echo $(( (f-5000)/5 ))
  elif [ "$f" -ge 5955 ] && [ "$f" -le 7115 ]; then echo $(( (f-5950)/5 ))
  else echo "?"; fi
}
band() { local f=${1%.*}; [ "$f" -lt 3000 ] && echo "2.4 GHz" || { [ "$f" -lt 5925 ] && echo "5 GHz" || echo "6 GHz"; }; }

printf '%s╔══════════════════════════════════════════════════════════╗\n' "$B"
printf '║  Sensor health check — %-33s ║\n' "$(hostname)"
printf '║  %-55s ║\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '╚══════════════════════════════════════════════════════════╝%s\n' "$N"

# =============================================================================
section "SENSOR HEALTH"
kv "Host"        "$(hostname)"
kv "Board"       "$(tr -d '\0' 2>/dev/null </proc/device-tree/model || echo n/a)"
kv "OS"          "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-n/a}")"
kv "Kernel"      "$(uname -r)"
kv "Uptime"      "$(uptime -p)"
kv "Load"        "$(cut -d' ' -f1-3 /proc/loadavg)  ($(nproc) cores)"
t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
if [ -n "$t" ]; then
  t=$((t/1000)); kv "Temp. CPU" "${t} °C"
  [ "$t" -ge 75 ] && warn "High temperature (CPU throttling risk)"
fi
kv "Memory"      "$(free -m | awk '/Mem:/{printf "%s / %s MB used (%d%%)", $3, $2, $3*100/$2}')"
kv "Disk /"      "$(df -h / | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"
pct=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
[ "${pct:-0}" -ge 85 ] && warn "Low disk space"
th=$(vcgencmd get_throttled 2>/dev/null); [ -n "$th" ] && kv "Throttling" "$th"

# =============================================================================
section "NETWORK"
echo "  ${B}Interfaces${N}"
ip -br addr | sed 's/^/    /'
echo; echo "  ${B}Routes${N}"
ip route | sed 's/^/    /'
GW=$(ip route show default | awk '/default/{print $3; exit}')
GWIF=$(ip route show default | awk '/default/{print $5; exit}')
echo
kv "Gateway"        "${GW:-none} (via ${GWIF:-?})"
kv "DNS"            "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
have resolvectl && kv "DNS (resolved)" "$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!=""{printf "%s ", $2}')"
kv "Public IP"      "$(curl -s -m 5 https://ifconfig.me 2>/dev/null || echo n/a)"
have tailscale && kv "Tailscale" "$(tailscale ip -4 2>/dev/null || echo 'not connected')"

# =============================================================================
section "WI-FI LINK"
[ -z "$IFACE" ] && IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
if ! have iw; then
  warn "iw missing: sudo apt install iw"
elif [ -z "$IFACE" ]; then
  warn "No Wi-Fi interface found (USB adapter plugged in?)"
else
  DRV=$(basename "$(readlink -f /sys/class/net/$IFACE/device/driver 2>/dev/null)" 2>/dev/null)
  kv "Interface"   "$IFACE  (driver ${DRV:-?})"
  [ "$IFACE" = "$GWIF" ] && kv "Default route" "${G}yes — Orb traffic goes over Wi-Fi${N}" \
                         || kv "Default route" "${Y}no — traffic goes over ${GWIF:-?}${N}"
  LINK=$(iw dev "$IFACE" link 2>/dev/null)
  if echo "$LINK" | grep -q "Not connected"; then
    warn "Wi-Fi not associated"
  else
    FREQ=$(echo "$LINK" | awk '/freq:/{print $2}')
    kv "SSID"        "$(echo "$LINK" | sed -n 's/^\s*SSID: //p')"
    kv "BSSID"       "$(echo "$LINK" | awk '/Connected to/{print $3}')"
    [ -n "$FREQ" ] && kv "Band / channel" "$(band "$FREQ") · channel $(freq2ch "$FREQ") · ${FREQ%.*} MHz"
    WIDTH=$(iw dev "$IFACE" info 2>/dev/null | sed -n 's/.*width: \([0-9]* MHz\).*/\1/p')
    [ -n "$WIDTH" ] && kv "Width" "$WIDTH"
    SIG=$(echo "$LINK" | awk '/signal:/{print $2}')
    kv "RSSI"        "${SIG} dBm"
    [ -n "$SIG" ] && [ "$SIG" -lt -70 ] && warn "Weak signal (< -70 dBm)"
    kv "RX (PHY)"    "$(echo "$LINK" | sed -n 's/^\s*rx bitrate: //p')"
    kv "TX (PHY)"    "$(echo "$LINK" | sed -n 's/^\s*tx bitrate: //p')"

    SD=$(iw dev "$IFACE" station dump 2>/dev/null)
    if [ -n "$SD" ]; then
      echo; echo "  ${B}Station dump${N}"
      g() { echo "$SD" | sed -n "s/^\s*$1:\s*//p" | head -1; }
      kv "Signal avg"     "$(g 'signal avg')"
      kv "Expected tput"  "$(g 'expected throughput')"
      kv "Connected for"  "$(g 'connected time')"
      kv "Inactive"       "$(g 'inactive time')"
      TXP=$(g 'tx packets'); TXR=$(g 'tx retries'); TXF=$(g 'tx failed')
      kv "TX packets"     "${TXP:-?}  retries ${TXR:-?}  failed ${TXF:-?}"
      if [ -n "$TXP" ] && [ "${TXP:-0}" -gt 0 ] && [ -n "$TXR" ]; then
        RR=$(( TXR * 100 / TXP )); kv "Retry rate" "${RR} %"
        [ "$RR" -ge 15 ] && warn "High retry rate (≥ 15 %)"
      fi
      kv "RX packets"     "$(g 'rx packets')  drop $(g 'rx drop misc')"
      kv "Beacon loss"    "$(g 'beacon loss')"
    fi
  fi

  # ---------------------------------------------------------------------------
  if [ "$NOSCAN" -eq 0 ]; then
    section "NEARBY APs"
    SCAN=""
    for _ in 1 2 3; do
      SCAN=$($SUDO iw dev "$IFACE" scan 2>&1) && break
      echo "$SCAN" | grep -qi busy || break
      sleep 2
    done
    if echo "$SCAN" | grep -qiE "password is required|not permitted|Operation not"; then
      warn "Scan refused: run as root, or allow 'sudo iw' (prepare-sensor.sh)"
    elif ! echo "$SCAN" | grep -q '^BSS '; then
      warn "Scan failed: $(echo "$SCAN" | head -1)"
    else
      printf '  %s%-28s %-17s %-7s %4s %7s %6s %-7s%s\n' "$B" "SSID" "BSSID" "Band" "Ch" "Width" "RSSI" "Sec" "$N"
      echo "$SCAN" | awk '
        function flush() { if (bss!="") printf "%s|%s|%s|%s|%s|%s|%s\n", sig, ssid, bss, freq, width, sec, assoc }
        /^BSS /           { flush(); bss=substr($2,1,17); ssid=""; freq=""; sig="-999"; width="20"; sec="Open"; assoc=($0 ~ /associated/) ? "●" : "" }
        /^\tfreq:/        { freq=int($2) }
        /^\tsignal:/      { sig=int($2) }
        /^\tSSID:/        { ssid=substr($0, index($0,"SSID:")+6) }
        /^\tRSN:/         { sec="WPA2/3" }
        /^\tWPA:/         { if (sec=="Open") sec="WPA" }
        /channel width: [0-9]+ \(/ { if (match($0,/\([0-9]+ MHz\)/)) { w=substr($0,RSTART+1,RLENGTH-6)+0; if (w > width+0) width=w } }
        END { flush() }' 2>/dev/null | sort -t'|' -k1,1nr | \
      while IFS='|' read -r sig ssid bss freq width sec assoc; do
        [ -z "$ssid" ] && ssid="(hidden)"
        printf '  %-28.28s %-17s %-7s %4s %4s MHz %4s %-7s %s\n' \
          "$ssid" "$bss" "$(band "${freq:-0}")" "$(freq2ch "${freq:-0}")" "$width" "$sig" "$sec" "$assoc"
      done
      kv "Total BSS" "$(echo "$SCAN" | grep -c '^BSS ')"
    fi
  fi
fi

# =============================================================================
section "CONNECTIVITY"
TARGETS="${TARGET:-}"
[ -z "$TARGETS" ] && TARGETS="${GW:+$GW }1.1.1.1"
for T in $TARGETS; do
  echo "  ${B}ping $T${N}"
  ping -c 10 -i 0.3 -W 2 "$T" 2>&1 | tail -2 | sed 's/^/    /'
done

s0=$(date +%s%N)
if getent ahosts orb.net >/dev/null 2>&1; then kv "DNS orb.net" "OK ($(( ($(date +%s%N)-s0)/1000000 )) ms)"
else warn "DNS resolution failed (orb.net)"; fi

TT=${TARGET:-1.1.1.1}
echo; echo "  ${B}Path to $TT${N}"
if have tracepath; then tracepath -n -m 15 "$TT" 2>&1 | sed 's/^/    /'
elif have traceroute; then traceroute -n -m 15 -w 2 "$TT" 2>&1 | sed 's/^/    /'
else warn "tracepath/traceroute missing: sudo apt install iputils-tracepath"; fi

if [ -n "$IPERF" ]; then
  section "IPERF3 → $IPERF (${DUR} s)"
  if ! have iperf3; then
    warn "iperf3 missing: sudo apt install iperf3"
  else
    for dir in "" "-R"; do
      label=$([ -z "$dir" ] && echo "Upload   (sensor → server)" || echo "Download (server → sensor)")
      res=$(iperf3 -c "$IPERF" -t "$DUR" $dir 2>&1)
      if echo "$res" | grep -q "receiver"; then
        kv "$label" "$(echo "$res" | awk '/receiver/{print $(NF-2), $(NF-1)}')"
        r=$(echo "$res" | awk '/sender/{print $(NF-1); exit}'); [ -z "$dir" ] && [ -n "$r" ] && kv "  retransmissions" "$r"
      else
        warn "$label: $(echo "$res" | tail -1)"
      fi
      sleep 1
    done
  fi
fi

# =============================================================================
section "ORB"
if systemctl list-unit-files orb.service >/dev/null 2>&1; then
  ST=$(systemctl is-active orb 2>/dev/null)
  [ "$ST" = "active" ] && kv "Service" "${G}${ST}${N}" || kv "Service" "${R}${ST}${N}"
  kv "Since"        "$(systemctl show orb -p ActiveEnterTimestamp --value 2>/dev/null)"
  kv "Version"      "$(dpkg-query -W -f='${Version}' orb 2>/dev/null || echo n/a)"
  kv "Auto-update"  "$(systemctl is-enabled orb-update.timer 2>/dev/null || echo n/a)"
  kv "Memory"       "$(systemctl show orb -p MemoryCurrent --value 2>/dev/null | awk '{ if ($1 ~ /^[0-9]+$/) printf "%.1f MB", $1/1048576; else print "n/a" }')"
  echo; echo "  ${B}Recent logs${N}"
  J=$($SUDO journalctl -u orb -n 15 --no-pager -o short-iso 2>/dev/null || journalctl -u orb -n 15 --no-pager -o short-iso 2>/dev/null)
  if [ -n "$J" ]; then echo "$J" | cut -c1-160 | sed 's/^/    /'
  else warn "Journal not readable (add your user to the systemd-journal group)"; fi
  echo "$J" | grep -qiE "level=(ERROR|WARN)" && warn "Errors or warnings in the Orb log"
else
  warn "Orb is not installed: curl -fsSL https://pkgs.orb.net/install.sh | sh"
fi

printf '\n%s── End of diagnostic ──%s\n' "$B" "$N"
