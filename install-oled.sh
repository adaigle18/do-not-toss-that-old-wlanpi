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
#!/usr/bin/env python3
"""
oled-status.py — Status display for the NanoHat OLED (SSD1306 128x64, I2C)
and/or a virtual screen served over HTTP — for Orb sensors on NanoPi.

Pages rotate automatically:
  1. Identity: hostname, LAN IP, Tailscale IP, Wi-Fi IP, Orb, temperature
  2. Wi-Fi   : SSID, band/channel, RSSI, PHY rate
  3. System  : load, memory, disk, uptime

OLED_MODE = hw (physical OLED) | web (virtual screen on :8088) | both
"""
import os
import re
import io
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unicodedata

from luma.core.interface.serial import i2c
from luma.core.render import canvas
from luma.oled.device import ssd1306
from PIL import ImageFont

I2C_BUS = int(os.environ.get("OLED_I2C_BUS", "0"))
I2C_ADDR = int(os.environ.get("OLED_I2C_ADDR", "0x3c"), 16)
PAGE_SECONDS = int(os.environ.get("OLED_PAGE_SECONDS", "5"))
ROTATE = int(os.environ.get("OLED_ROTATE", "0"))  # 0 or 2 (180°)
MODE = os.environ.get("OLED_MODE", "hw")          # hw | web | both
WEB_PORT = int(os.environ.get("OLED_WEB_PORT", "8088"))
WEB_SCALE = 4
LINE_H = 10


def sh(cmd: str, timeout: int = 4) -> str:
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""


def ipv4(iface_prefixes) -> str:
    out = sh("ip -4 -o addr show")
    for line in out.splitlines():
        parts = line.split()
        if len(parts) > 3 and parts[1].startswith(iface_prefixes):
            return parts[3].split("/")[0]
    return "—"


def tailscale_ip() -> str:
    ip = sh("tailscale ip -4 2>/dev/null")
    return ip.splitlines()[0] if ip else "—"


def orb_state() -> str:
    st = sh("systemctl is-active orb")
    return {"active": "active", "inactive": "stopped", "failed": "FAILED"}.get(st, st or "n/a")


def cpu_temp() -> str:
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return f"{int(f.read()) // 1000}°C"
    except OSError:
        return "—"


def wifi_iface() -> str:
    m = re.search(r"Interface\s+(\S+)", sh("iw dev"))
    return m.group(1) if m else ""


def freq_to_channel(f: int) -> str:
    if f == 2484:
        return "14"
    if 2412 <= f <= 2472:
        return str((f - 2407) // 5)
    if 5150 <= f <= 5895:
        return str((f - 5000) // 5)
    if 5955 <= f <= 7115:
        return str((f - 5950) // 5)
    return "?"


def wifi_lines() -> list:
    iface = wifi_iface()
    if not iface:
        return ["Wi-Fi", "", "No USB adapter", "detected"]
    link = sh(f"iw dev {iface} link")
    if not link or "Not connected" in link:
        return ["Wi-Fi", iface[:21], "", "Not associated"]
    ssid = re.search(r"SSID:\s*(.*)", link)
    freq = re.search(r"freq:\s*([\d.]+)", link)
    sig = re.search(r"signal:\s*(-?\d+)", link)
    rx = re.search(r"rx bitrate:\s*([\d.]+)", link)
    f = int(float(freq.group(1))) if freq else 0
    band = "2.4G" if f < 3000 else ("5G" if f < 5925 else "6G")
    return [
        "Wi-Fi",
        (ssid.group(1) if ssid else "?")[:21],
        f"{band} ch{freq_to_channel(f)}  {sig.group(1) if sig else '?'} dBm",
        f"RX {rx.group(1) if rx else '?'} Mb/s",
    ]


def system_lines() -> list:
    load = open("/proc/loadavg").read().split()[0]
    mem = sh("free -m | awk '/Mem:/{printf \"%d/%dMB\", $3, $2}'")
    disk = sh("df -h / | awk 'NR==2{print $5}'")
    up = sh("uptime -p").replace("up ", "")
    up = up.replace(" hours", "h").replace(" hour", "h").replace(" minutes", "m") \
           .replace(" minute", "m").replace(" days", "d").replace(" day", "d").replace(",", "")
    return ["System", f"Load {load}  {cpu_temp()}", f"RAM {mem}", f"Disk {disk}", f"Up {up}"[:21]]


def identity_lines() -> list:
    return [
        socket.gethostname()[:21],
        f"LAN {ipv4(('eth', 'end', 'enx'))}",
        f"TS  {tailscale_ip()}",
        f"WLN {ipv4(('wl',))}",
        f"Orb {orb_state()}  {cpu_temp()}",
    ]


PAGES = [identity_lines, wifi_lines, system_lines]


def ascii_safe(txt: str) -> str:
    """The built-in font is ASCII only: strip accents and symbols."""
    txt = txt.replace("°C", "C").replace("—", "-").replace("·", "-")
    txt = unicodedata.normalize("NFKD", txt)
    return "".join(c for c in txt if ord(c) < 128)


def draw(device, font, lines, page_idx):
    lines = [ascii_safe(str(x)) for x in lines]
    with canvas(device) as d:
        # Title (line 0), underlined
        d.text((0, 0), lines[0], font=font, fill="white")
        d.line((0, LINE_H + 1, device.width, LINE_H + 1), fill="white")
        for i, txt in enumerate(lines[1:6], start=1):
            d.text((0, i * LINE_H + 3), txt, font=font, fill="white")
        # Page indicator, bottom right
        for p in range(len(PAGES)):
            x = device.width - 4 * (len(PAGES) - p)
            y = device.height - 3
            if p == page_idx:
                d.rectangle((x, y, x + 2, y + 2), fill="white")
            else:
                d.point((x + 1, y + 1), fill="white")


# --------------------------------------------------------------------------- #
# Virtual screen (web mode): the same 128x64 image, served as an upscaled PNG
# --------------------------------------------------------------------------- #
_frame = {"png": b"", "t": 0.0}

HTML = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Virtual OLED — %(host)s</title>
<style>
 body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
      background:#2b2f36;font-family:-apple-system,Helvetica,Arial,sans-serif;color:#c9ced6}
 .case{background:#1c1f24;border-radius:22px;padding:34px 40px 26px;box-shadow:0 20px 50px #0008}
 .bezel{background:#0b0c0e;border-radius:8px;padding:14px}
 img{display:block;width:512px;height:256px;image-rendering:pixelated;filter:drop-shadow(0 0 2px #9ecbff55)}
 .row{display:flex;justify-content:space-between;align-items:center;margin-top:18px;font-size:13px}
 .btns span{display:inline-block;width:18px;height:18px;border-radius:50%%;margin-left:14px;
      background:radial-gradient(circle at 35%% 35%%,#f3d77a,#b08a1f)}
 .age{opacity:.6}
</style></head><body><div class="case"><div class="bezel"><img id="s" src="screen.png" alt="Virtual OLED screen"></div>
<div class="row"><span>%(host)s · virtual OLED</span><span class="btns"><span></span><span></span><span></span></span></div>
<div class="row age"><span id="a">—</span></div></div>
<script>
 const img=document.getElementById('s'), a=document.getElementById('a');
 setInterval(()=>{img.src='screen.png?'+Date.now();
   fetch('age').then(r=>r.text()).then(t=>a.textContent='Updated '+t+' s ago').catch(()=>a.textContent='Sensor unreachable');},1000);
</script></body></html>"""


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            self._send(200, "text/html; charset=utf-8",
                       (HTML % {"host": socket.gethostname()}).encode())
        elif path == "/screen.png" and _frame["png"]:
            self._send(200, "image/png", _frame["png"])
        elif path == "/age":
            self._send(200, "text/plain", str(int(time.time() - _frame["t"])).encode())
        else:
            self._send(404, "text/plain", b"404")


def start_web():
    srv = ThreadingHTTPServer(("0.0.0.0", WEB_PORT), _Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"Virtual OLED: http://{socket.gethostname()}:{WEB_PORT}", file=sys.stderr)


def publish(device):
    img = device.image.convert("L").resize(
        (device.width * WEB_SCALE, device.height * WEB_SCALE), resample=0)
    # slight blue tint, like a real OLED
    from PIL import ImageOps
    img = ImageOps.colorize(img, black=(0, 0, 0), white=(214, 235, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    _frame["png"], _frame["t"] = buf.getvalue(), time.time()


def main():
    devices = []
    if MODE in ("hw", "both"):
        try:
            hw = ssd1306(i2c(port=I2C_BUS, address=I2C_ADDR), rotate=ROTATE)
            hw.contrast(160)
            devices.append(hw)
        except Exception as e:  # no screen, or I2C bus not enabled
            print(f"OLED not found on i2c-{I2C_BUS} @ {hex(I2C_ADDR)}: {e}", file=sys.stderr)
            if MODE == "hw":
                sys.exit(1)
    virtual = None
    if MODE in ("web", "both"):
        from luma.core.device import dummy
        virtual = dummy(width=128, height=64, mode="1")
        devices.append(virtual)
        start_web()
    if not devices:
        sys.exit(1)

    font = ImageFont.load_default()
    page = 0
    while True:
        try:
            lines = PAGES[page]()
            for dev in devices:
                draw(dev, font, lines, page)
        except Exception as e:
            for dev in devices:
                with canvas(dev) as d:
                    d.text((0, 0), "Display error", font=font, fill="white")
                    d.text((0, 12), ascii_safe(str(e))[:21], font=font, fill="white")
        if virtual is not None:
            publish(virtual)
        time.sleep(PAGE_SECONDS)
        page = (page + 1) % len(PAGES)


if __name__ == "__main__":
    main()
PYEOF

echo "==> systemd service"
cat > /etc/systemd/system/oled-status.service <<EOF
[Unit]
Description=Orb sensor status screen (OLED $MODE)
After=network-online.target tailscaled.service orb.service
Wants=network-online.target

[Service]
Environment=OLED_MODE=$MODE
Environment=OLED_I2C_BUS=$BUS
Environment=OLED_I2C_ADDR=$ADDR
Environment=OLED_WEB_PORT=$PORT
Environment=OLED_PAGE_SECONDS=5
ExecStart=/opt/oled-status/.venv/bin/python /opt/oled-status/oled-status.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable oled-status >/dev/null 2>&1

if [ "$MODE" = "hw" ] && [ ! -e /dev/i2c-$BUS ]; then
  echo "⚠ /dev/i2c-$BUS missing: reboot (sync; reboot) — the screen will start on its own."
  exit 0
fi
systemctl restart oled-status; sleep 6
if systemctl is-active --quiet oled-status; then
  echo "✔ Service active"
  if [ "$MODE" != "hw" ]; then
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/screen.png" \
      && echo "✔ Virtual screen: http://$(hostname):$PORT  or  http://$(hostname -I | awk '{print $1}'):$PORT" \
      || echo "⚠ The web page isn't answering yet — try again in a few seconds"
  fi
else
  echo "✘ Service failed:"; journalctl -u oled-status -n 15 --no-pager
fi
