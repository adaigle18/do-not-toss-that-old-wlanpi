#!/usr/bin/env python3
"""
Orb Sensors MCP server
Runs locally on your laptop and queries NanoPi/Orb sensors over SSH (LAN or Tailscale).
Nothing is installed or listening on the sensors: only read-only, allow-listed
commands run over SSH.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shlex
from pathlib import Path

try:  # SDK MCP 2.x
    from mcp.server.mcpserver import MCPServer as _Server
except ImportError:  # SDK MCP 1.x
    from mcp.server.fastmcp import FastMCP as _Server

CONFIG_PATH = Path(
    os.environ.get("ORB_SENSORS_CONFIG", Path(__file__).with_name("sensors.json"))
)

mcp = _Server(
    "orb-sensors",
    instructions=(
        "Diagnostic tools for Wi-Fi / Orb sensors (NanoPi on Armbian). "
        "All commands are read-only and run over SSH (LAN or Tailscale). "
        "Start with list_sensors."
    ),
)

SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=8",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
    "-o", "LogLevel=ERROR",
]

TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.\-:]{0,252}$")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,15}$")


# --------------------------------------------------------------------------- #
# Configuration and SSH
# --------------------------------------------------------------------------- #
def load_sensors() -> dict:
    data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    return data.get("sensors", {})


def get_sensor(name: str) -> dict:
    sensors = load_sensors()
    if name not in sensors:
        raise ValueError(
            f"Unknown sensor: {name!r}. Configured sensors: {', '.join(sensors) or 'none'}"
        )
    return sensors[name]


def check_target(target: str) -> str:
    if not TARGET_RE.match(target):
        raise ValueError(f"Invalid target: {target!r} (hostname or IP address expected)")
    return target


async def ssh_run(name: str, command: str, timeout: int = 30) -> tuple[int, str, str]:
    s = get_sensor(name)
    dest = f"{s.get('user', 'root')}@{s.get('host', name)}"
    args = ["ssh", *SSH_OPTS]
    if s.get("port"):
        args += ["-p", str(int(s["port"]))]
    if s.get("identity_file"):
        args += ["-i", os.path.expanduser(s["identity_file"])]
    args += [dest, command]

    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, "", f"Timed out ({timeout} s)"
    return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace")


def iface_snippet(name: str) -> str:
    """Shell snippet that sets $IF (configured or auto-detected Wi-Fi interface)."""
    iface = get_sensor(name).get("wifi_iface", "auto")
    if iface and iface != "auto":
        if not IFACE_RE.match(iface):
            raise ValueError(f"Invalid interface name in sensors.json: {iface!r}")
        return f"IF={shlex.quote(iface)}; "
    return (
        "IF=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}'); "
        '[ -z "$IF" ] && { echo "__NO_WIFI__"; exit 3; }; '
    )


def fmt_error(name: str, rc: int, out: str, err: str) -> str:
    if "__NO_WIFI__" in out:
        return f"[{name}] No Wi-Fi interface found (USB adapter plugged in?)."
    msg = (err or out).strip() or "no output"
    return f"[{name}] Failed (code {rc}): {msg}"


# --------------------------------------------------------------------------- #
# Parsing iw output
# --------------------------------------------------------------------------- #
def freq_to_channel(freq: float) -> int | None:
    f = int(round(freq))
    if f == 2484:
        return 14
    if 2412 <= f <= 2472:
        return (f - 2407) // 5
    if 5150 <= f <= 5895:
        return (f - 5000) // 5
    if 5955 <= f <= 7115:
        return (f - 5950) // 5
    return None


def band_of(freq: float) -> str:
    if freq < 3000:
        return "2.4 GHz"
    if freq < 5925:
        return "5 GHz"
    return "6 GHz"


def decode_ssid(raw: str) -> str:
    """iw prints non-ASCII SSID bytes as \\xNN: turn them back into UTF-8."""
    try:
        return raw.encode("latin-1").decode("unicode_escape").encode("latin-1").decode("utf-8")
    except Exception:
        return raw


def parse_iw_link(text: str) -> dict:
    info: dict = {}
    if "Not connected" in text:
        return {"connected": False}
    m = re.search(r"Connected to ([0-9a-f:]{17})", text, re.I)
    if m:
        info["connected"] = True
        info["bssid"] = m.group(1).lower()
    for key, rx in {
        "ssid": r"^\s*SSID:\s*(.*)$",
        "freq": r"^\s*freq:\s*([\d.]+)",
        "signal": r"^\s*signal:\s*(-?\d+)",
        "rx_bitrate": r"^\s*rx bitrate:\s*(.*)$",
        "tx_bitrate": r"^\s*tx bitrate:\s*(.*)$",
    }.items():
        mm = re.search(rx, text, re.M)
        if mm:
            info[key] = mm.group(1).strip()
    if "ssid" in info:
        info["ssid"] = decode_ssid(info["ssid"])
    if "freq" in info:
        f = float(info["freq"])
        info["channel"] = freq_to_channel(f)
        info["band"] = band_of(f)
    return info


def parse_iw_scan(text: str) -> list[dict]:
    bsses: list[dict] = []
    cur: dict | None = None
    for line in text.splitlines():
        m = re.match(r"^BSS ([0-9a-f:]{17})", line, re.I)
        if m:
            cur = {"bssid": m.group(1).lower(), "ssid": "", "associated": "associated" in line,
                   "security": "Open", "width": ""}
            bsses.append(cur)
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("freq:"):
            try:
                cur["freq"] = float(s.split()[1])
            except (IndexError, ValueError):
                pass
        elif s.startswith("signal:"):
            try:
                cur["signal"] = float(s.split()[1])
            except (IndexError, ValueError):
                pass
        elif s.startswith("SSID:"):
            cur["ssid"] = decode_ssid(s[5:].strip())
        elif s.startswith("RSN:"):
            cur["security"] = "WPA2/3"
        elif s.startswith("WPA:") and cur["security"] == "Open":
            cur["security"] = "WPA"
        elif "channel width:" in s:
            mw = re.search(r"\((\d+ MHz)\)", s)
            if mw and (not cur["width"] or mw.group(1) != "20 MHz"):
                cur["width"] = mw.group(1)
    for b in bsses:
        if "freq" in b:
            b["channel"] = freq_to_channel(b["freq"])
            b["band"] = band_of(b["freq"])
    return bsses


# --------------------------------------------------------------------------- #
# MCP tools
# --------------------------------------------------------------------------- #
@mcp.tool()
def list_sensors() -> str:
    """List configured sensors (name, host, user, site)."""
    sensors = load_sensors()
    if not sensors:
        return f"No sensors in {CONFIG_PATH}"
    lines = ["| Sensor | Host | User | Site | Wi-Fi interface |", "|---|---|---|---|---|"]
    for n, s in sensors.items():
        lines.append(
            f"| {n} | {s.get('host', n)} | {s.get('user', 'root')} | {s.get('site', '')} | {s.get('wifi_iface', 'auto')} |"
        )
    return "\n".join(lines)


@mcp.tool()
async def sensor_health(sensor: str) -> str:
    """Sensor hardware health: uptime, load, CPU temperature, memory, disk, kernel."""
    cmd = (
        "echo \"host: $(hostname)\"; echo \"kernel: $(uname -r)\"; "
        "echo \"uptime: $(uptime -p)\"; echo \"load: $(cut -d' ' -f1-3 /proc/loadavg)\"; "
        "t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null); "
        "[ -n \"$t\" ] && echo \"cpu_temp: $((t/1000)) °C\"; "
        "free -m | awk '/Mem:/{printf \"mem: %s/%s MB used\\n\", $3, $2}'; "
        "df -h / | awk 'NR==2{printf \"disk: %s/%s (%s)\\n\", $3, $2, $5}'"
    )
    rc, out, err = await ssh_run(sensor, cmd, 20)
    return f"[{sensor}]\n{out.strip()}" if rc == 0 else fmt_error(sensor, rc, out, err)


@mcp.tool()
async def net_status(sensor: str) -> str:
    """Interfaces, addresses, routes and DNS (shows which interface carries the default route)."""
    cmd = (
        "echo '## Interfaces'; ip -br addr; echo; echo '## Routes'; ip route; "
        "echo; echo '## DNS'; grep -E '^(nameserver|search)' /etc/resolv.conf; "
        "echo; echo '## Tailscale'; (tailscale ip -4 2>/dev/null || echo 'n/d')"
    )
    rc, out, err = await ssh_run(sensor, cmd, 20)
    return f"[{sensor}]\n{out.strip()}" if rc == 0 else fmt_error(sensor, rc, out, err)


@mcp.tool()
async def wifi_link(sensor: str) -> str:
    """Current Wi-Fi link: SSID, BSSID, band, channel, RSSI, PHY rates (MCS/NSS/width)."""
    cmd = iface_snippet(sensor) + 'echo "iface: $IF"; iw dev "$IF" link; echo "---"; iw dev "$IF" info'
    rc, out, err = await ssh_run(sensor, cmd, 20)
    if rc != 0:
        return fmt_error(sensor, rc, out, err)
    link_part = out.split("---")[0]
    info = parse_iw_link(link_part)
    if not info.get("connected"):
        return f"[{sensor}] Wi-Fi not associated.\n\n{out.strip()}"
    return (
        f"[{sensor}] {info.get('ssid', '?')} — BSSID {info.get('bssid')}\n"
        f"Band {info.get('band')} · channel {info.get('channel')} · RSSI {info.get('signal')} dBm\n"
        f"RX : {info.get('rx_bitrate', 'n/d')}\nTX : {info.get('tx_bitrate', 'n/d')}\n\n"
        f"--- raw ---\n{out.strip()}"
    )


@mcp.tool()
async def wifi_scan(sensor: str, ssid_filter: str = "", band: str = "") -> str:
    """
    Scan nearby APs seen by the sensor (root, or passwordless sudo for iw — see prepare-sensor.sh).
    ssid_filter: SSID substring (optional). band: '2.4', '5' or '6' (optional).
    """
    cmd = iface_snippet(sensor) + (
        'S=""; [ "$(id -u)" -ne 0 ] && S="sudo -n"; '
        'for i in 1 2 3; do OUT=$($S iw dev "$IF" scan 2>&1) && { echo "$OUT"; exit 0; }; '
        'echo "$OUT" | grep -qi busy || { echo "$OUT" >&2; exit 1; }; sleep 2; done; exit 1'
    )
    rc, out, err = await ssh_run(sensor, cmd, 45)
    if rc != 0:
        if "a password is required" in err or "sudo" in err:
            return f"[{sensor}] sudo refused for iw — run prepare-sensor.sh on the sensor, or connect as root."
        return fmt_error(sensor, rc, out, err)
    bsses = parse_iw_scan(out)
    if ssid_filter:
        bsses = [b for b in bsses if ssid_filter.lower() in b["ssid"].lower()]
    if band:
        bsses = [b for b in bsses if b.get("band", "").startswith(band)]
    bsses.sort(key=lambda b: b.get("signal", -999), reverse=True)
    if not bsses:
        return f"[{sensor}] No matching BSS."
    rows = ["| SSID | BSSID | Band | Channel | Width | RSSI | Security | Assoc. |",
            "|---|---|---|---|---|---|---|---|"]
    for b in bsses:
        rows.append(
            f"| {b['ssid'] or '(hidden)'} | {b['bssid']} | {b.get('band', '')} | {b.get('channel', '')} | "
            f"{b['width'] or 'n/a'} | {b.get('signal', '')} | {b['security']} | {'●' if b['associated'] else ''} |"
        )
    return f"[{sensor}] {len(bsses)} BSS\n" + "\n".join(rows)


@mcp.tool()
async def ping(sensor: str, target: str, count: int = 10) -> str:
    """Ping from the sensor to a target (IP or hostname). count: 1 to 50."""
    target = check_target(target)
    count = max(1, min(int(count), 50))
    rc, out, err = await ssh_run(sensor, f"ping -c {count} -W 2 {shlex.quote(target)}", count * 3 + 15)
    if rc not in (0, 1):
        return fmt_error(sensor, rc, out, err)
    summary = "\n".join(out.strip().splitlines()[-3:])
    return f"[{sensor}] ping {target}\n{summary}"


@mcp.tool()
async def trace_path(sensor: str, target: str) -> str:
    """Network path from the sensor to a target (tracepath, else traceroute), 20 hops max."""
    t = shlex.quote(check_target(target))
    cmd = (
        f"if command -v tracepath >/dev/null; then tracepath -n -m 20 {t}; "
        f"elif command -v traceroute >/dev/null; then traceroute -n -m 20 -w 2 {t}; "
        "else echo 'tracepath/traceroute missing — apt install iputils-tracepath'; exit 2; fi"
    )
    rc, out, err = await ssh_run(sensor, cmd, 90)
    return f"[{sensor}]\n{out.strip()}" if out.strip() else fmt_error(sensor, rc, out, err)


@mcp.tool()
async def dns_lookup(sensor: str, name: str) -> str:
    """DNS resolution from the sensor (system resolver), with response time."""
    n = shlex.quote(check_target(name))
    cmd = (
        "s=$(date +%s%N); r=$(getent ahosts " + n + " | awk '{print $1}' | sort -u); "
        "e=$(date +%s%N); echo \"$r\"; echo \"time: $(( (e-s)/1000000 )) ms\""
    )
    rc, out, err = await ssh_run(sensor, cmd, 20)
    if not out.strip() or out.strip().startswith("time:"):
        return f"[{sensor}] Resolution failed for {name}. {out.strip()}"
    return f"[{sensor}] {name}\n{out.strip()}"


@mcp.tool()
async def iperf3_test(sensor: str, server: str, duration: int = 10, reverse: bool = False,
                      port: int = 5201) -> str:
    """
    iperf3 throughput test from the sensor to an iperf3 server.
    reverse=False: sensor → server (upload); reverse=True: server → sensor (download).
    duration: 3 to 30 s.
    """
    srv = shlex.quote(check_target(server))
    duration = max(3, min(int(duration), 30))
    flags = "-R " if reverse else ""
    cmd = (
        "command -v iperf3 >/dev/null || { echo 'iperf3 missing — apt install iperf3'; exit 2; }; "
        f"iperf3 -c {srv} -p {int(port)} -t {duration} {flags}-J"
    )
    rc, out, err = await ssh_run(sensor, cmd, duration + 20)
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return fmt_error(sensor, rc, out, err)
    if "error" in data:
        return f"[{sensor}] iperf3: {data['error']}"
    end = data.get("end", {})
    sent = end.get("sum_sent", {})
    recv = end.get("sum_received", {})
    direction = "download (server → sensor)" if reverse else "upload (sensor → server)"
    return (
        f"[{sensor}] iperf3 {direction}, {duration} s to {server}\n"
        f"Sent: {sent.get('bits_per_second', 0) / 1e6:.1f} Mbit/s · "
        f"retransmits: {sent.get('retransmits', 'n/a')}\n"
        f"Received: {recv.get('bits_per_second', 0) / 1e6:.1f} Mbit/s"
    )


@mcp.tool()
async def orb_status(sensor: str, lines: int = 30) -> str:
    """Orb service status on the sensor (active, version, since when) and recent log lines."""
    lines = max(5, min(int(lines), 200))
    cmd = (
        "echo \"service: $(systemctl is-active orb)\"; "
        "echo \"since: $(systemctl show orb -p ActiveEnterTimestamp --value)\"; "
        "echo \"version: $(dpkg-query -W -f='${Version}' orb 2>/dev/null)\"; "
        "echo \"auto-update: $(systemctl is-enabled orb-update.timer 2>/dev/null)\"; echo; "
        f"journalctl -u orb -n {lines} --no-pager -o short-iso 2>&1 | cut -c1-220"
    )
    rc, out, err = await ssh_run(sensor, cmd, 25)
    return f"[{sensor}]\n{out.strip()}" if out.strip() else fmt_error(sensor, rc, out, err)


@mcp.tool()
async def compare_wifi(sensors: list[str] | None = None) -> str:
    """Compare the Wi-Fi link of several sensors in parallel (all of them if the list is empty)."""
    names = sensors or list(load_sensors())

    async def one(n: str) -> list[str]:
        try:
            cmd = iface_snippet(n) + 'iw dev "$IF" link'
            rc, out, err = await ssh_run(n, cmd, 20)
        except ValueError as e:
            return [n, "—", "—", "—", "—", str(e)]
        if rc != 0:
            return [n, "—", "—", "—", "—", re.sub(r"^\[[^\]]+\]\s*", "", fmt_error(n, rc, out, err))[:70]]
        i = parse_iw_link(out)
        if not i.get("connected"):
            return [n, "not associated", "—", "—", "—", ""]
        return [n, i.get("ssid", "?"), i.get("bssid", "?"),
                f"{i.get('band')} / ch {i.get('channel')}", f"{i.get('signal')} dBm",
                i.get("rx_bitrate", "")]

    results = await asyncio.gather(*(one(n) for n in names))
    rows = ["| Sensor | SSID | BSSID | Band / channel | RSSI | RX bitrate |", "|---|---|---|---|---|---|"]
    rows += ["| " + " | ".join(r) + " |" for r in results]
    return "\n".join(rows)


if __name__ == "__main__":
    mcp.run()
