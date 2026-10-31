#!/bin/bash
# =============================================================================
#  diag.sh — Run sensor-diag.sh on one or more sensors FROM YOUR LAPTOP.
#  Nothing is copied to the sensor: the script is streamed over SSH (stdin).
#
#  Usage:
#     ./diag.sh root@192.168.1.50                    # one sensor
#     ./diag.sh root@sensor-01 -- -t 8.8.8.8         # options after --
#     ./diag.sh root@sensor-01 -- -p 100.64.0.5 -d 15   # with iperf3
#     ./diag.sh all                                  # every sensor in sensors.json
#
#  Reports are saved to ./reports/<sensor>_<date>.txt
# =============================================================================
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/sensor-diag.sh"
mkdir -p "$DIR/reports"

HOSTS=(); OPTS=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; OPTS=("$@"); break; fi
  HOSTS+=("$1"); shift
done
[ ${#HOSTS[@]} -eq 0 ] && { sed -n '3,12p' "$0"; exit 1; }

if [ "${HOSTS[0]}" = "all" ]; then
  HOSTS=()
  while IFS= read -r h; do HOSTS+=("$h"); done < <(python3 - "$DIR/sensors.json" <<'PY'
import json, sys
for n, s in json.load(open(sys.argv[1]))["sensors"].items():
    print(f"{s.get('user','root')}@{s.get('host', n)}")
PY
)
fi

for H in "${HOSTS[@]}"; do
  NAME="${H#*@}"
  OUT="$DIR/reports/${NAME}_$(date +%Y%m%d-%H%M).txt"
  echo "▶ $H"
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$H" \
      "bash -s -- ${OPTS[*]:-}" < "$SCRIPT" | tee "$OUT"
  if [ "${PIPESTATUS[0]}" -eq 0 ] && grep -q "End of diagnostic" "$OUT"; then
    echo "✔ Report: $OUT"
  else
    rm -f "$OUT"; echo "✘ Could not connect to $H — no report saved"
  fi
  echo
done
