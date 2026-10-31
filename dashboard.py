#!/usr/bin/env python3
"""
NanoPi (recycled) + Orb Sensor — local dashboard

Drives the sensors listed in sensors.json over SSH:
  • live status (mode, Wi-Fi link, Orb, capture)
  • one-click switch: Orb mode  <->  capture mode (via nanopi-recycled.sh)
  • nearby AP scan: click a row to set the capture band / channel
  • the sensor's status screen (virtual OLED) in the middle of the page

Listens on 127.0.0.1 only. Python standard library only.
Start: ./dashboard.sh   (or python3 dashboard.py)
"""
import json
import os
import re
import shlex
import subprocess
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE = Path(__file__).resolve().parent
SENSORS = BASE / "sensors.json"
NPR = BASE / "nanopi-recycled.sh"
CAPTURES = BASE / "captures"
PORT = int(os.environ.get("DASH_PORT", "8787"))
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto", "-o", f"ControlPath={Path.home()}/.ssh/cm-npr-%C",
            "-o", "ControlPersist=120", "-o", "ServerAliveInterval=10"]
IFACE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")

procs = {}                       # sensor -> capture Popen
status_cache = {}                # sensor -> (timestamp, data)
sensor_locks = {}                # sensor -> lock (one status SSH call at a time)
STATUS_TTL = 4
logs = {}                        # sensor -> deque of log lines
lock = threading.Lock()


# --------------------------------------------------------------------------- #
def sensors():
    try:
        return json.loads(SENSORS.read_text(encoding="utf-8")).get("sensors", {})
    except Exception:
        return {}


def target(name):
    s = sensors().get(name)
    if not s:
        raise ValueError(f"unknown sensor: {name}")
    iface = s.get("wifi_iface", "auto")
    iface = "wlan0" if iface in ("", "auto") else iface
    if not IFACE_RE.match(iface):
        raise ValueError("interface invalide")
    return f"{s.get('user', 'root')}@{s.get('host', name)}", iface, s


def ssh(dest, cmd, timeout=15):
    try:
        p = subprocess.run(["ssh", *SSH_OPTS, dest, cmd], capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"


def log(name, line):
    entry = time.strftime("%H:%M:%S ") + line.rstrip()
    with lock:
        logs.setdefault(name, deque(maxlen=200)).append(entry)
    print(f"[{name}] {entry}", flush=True)


# --------------------------------------------------------------------------- #
STATUS_CMD = r"""
IF={iface}
t=$(iw dev $IF info 2>/dev/null); l=$(iw dev $IF link 2>/dev/null)
echo "mode=$(echo "$t" | awk '/type/{{print $2}}')"
echo "chan=$(echo "$t" | sed -n 's/.*channel \([0-9]*\).*/\1/p')"
echo "freq=$(echo "$t" | sed -n 's/.*channel [0-9]* (\([0-9]*\) MHz).*/\1/p')"
echo "width=$(echo "$t" | sed -n 's/.*width: \([0-9]*\) MHz.*/\1/p')"
echo "ssid=$(echo "$l" | sed -n 's/^\s*SSID: //p')"
echo "bssid=$(echo "$l" | awk '/Connected to/{{print $3}}')"
echo "signal=$(echo "$l" | awk '/signal:/{{print $2}}')"
echo "rx=$(echo "$l" | sed -n 's/^\s*rx bitrate: //p')"
echo "tx=$(echo "$l" | sed -n 's/^\s*tx bitrate: //p')"
echo "ip=$(ip -4 -o addr show $IF 2>/dev/null | awk '{{print $4}}')"
echo "client=$(systemctl is-active netplan-wpa-$IF.service 2>/dev/null)"
echo "orb=$(systemctl is-active orb 2>/dev/null)"
echo "oled=$(systemctl is-active oled-status 2>/dev/null)"
echo "oledmode=$(systemctl show oled-status -p Environment --value 2>/dev/null | grep -o 'OLED_MODE=[a-z]*' | cut -d= -f2)"
echo "capture=$(cat /run/nanopi-recycled.state 2>/dev/null)"
echo "temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))"
echo "load=$(cut -d' ' -f1 /proc/loadavg)"
echo "uptime=$(uptime -p | sed 's/^up //')"
echo "host=$(hostname)"
"""


def freq_to_band_ch(f):
    f = int(f)
    if f == 2484:
        return "2.4", 14
    if f < 3000:
        return "2.4", (f - 2407) // 5
    if f < 5925:
        return "5", (f - 5000) // 5
    return "6", (f - 5950) // 5


def status(name):
    lk = sensor_locks.setdefault(name, threading.Lock())
    with lk:
        hit = status_cache.get(name)
        if hit and time.time() - hit[0] < STATUS_TTL:
            d = dict(hit[1])
        else:
            d = _status(name)
            status_cache[name] = (time.time(), d)
    with lock:
        p = procs.get(name)
        d["local_capture"] = bool(p and p.poll() is None)
    return d


def _status(name):
    dest, iface, s = target(name)
    rc, out, err = ssh(dest, STATUS_CMD.format(iface=iface))
    if rc != 0:
        return {"ok": False, "error": (err or out).strip() or f"code {rc}"}
    d = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    d["ok"] = True
    d["oled_url"] = (f"http://{s.get('host', name)}:8088"
                     if d.get("oled") == "active" and d.get("oledmode") in ("web", "both") else "")
    return d


def scan(name):
    dest, iface, _ = target(name)
    rc, out, err = ssh(dest, f"iw dev {iface} scan 2>&1 || sudo -n iw dev {iface} scan 2>&1", timeout=40)
    aps, cur = [], None
    for line in out.splitlines():
        m = re.match(r"^BSS ([0-9a-f:]{17})", line, re.I)
        if m:
            cur = {"bssid": m.group(1).lower(), "ssid": "", "signal": -100, "freq": 0}
            aps.append(cur)
            continue
        if not cur:
            continue
        t = line.strip()
        if t.startswith("freq:"):
            try:
                cur["freq"] = int(float(t.split()[1]))
            except (IndexError, ValueError):
                pass
        elif t.startswith("signal:"):
            try:
                cur["signal"] = float(t.split()[1])
            except (IndexError, ValueError):
                pass
        elif t.startswith("SSID:"):
            raw = t[5:].strip()
            try:  # decode the \xNN escapes printed by iw
                raw = raw.encode("latin-1").decode("unicode_escape").encode("latin-1").decode("utf-8")
            except Exception:
                pass
            cur["ssid"] = raw
    aps = [a for a in aps if a["freq"]]
    for a in aps:
        a["band"], a["ch"] = freq_to_band_ch(a["freq"])
    aps.sort(key=lambda a: a["signal"], reverse=True)
    if not aps:
        return {"ok": False, "error": "no AP found (adapter in capture mode? or scan refused)", "raw": out[-300:]}
    return {"ok": True, "aps": aps[:40]}


def start_capture(name, p):
    dest, iface, _ = target(name)
    band = str(p.get("band", "5"))
    ch, width = int(p.get("ch", 36)), int(p.get("width", 20))
    if band not in ("2.4", "5", "6") or width not in (20, 40, 80, 160) or not (1 <= ch <= 233):
        raise ValueError("invalid band, channel or width")
    with lock:
        old = procs.get(name)
        if old and old.poll() is None:
            raise ValueError("a capture is already running on this sensor")
    args = ["/bin/bash", str(NPR), "capture", dest, "-b", band, "-c", str(ch), "-w", str(width), "-i", iface]
    if p.get("filter"):
        args += ["-f", str(p["filter"])[:200]]
    if p.get("snap"):
        args += ["-s", "256"]
    if int(p.get("duration", 0) or 0) > 0:
        args += ["-d", str(int(p["duration"]))]
    if p.get("to_file"):
        CAPTURES.mkdir(exist_ok=True)
        fname = CAPTURES / f"{name}_{band}GHz_ch{ch}_{time.strftime('%Y%m%d-%H%M%S')}.pcap"
        args += ["-o", str(fname)]
        log(name, f"Saving to: {fname}")
    log(name, "$ " + " ".join(shlex.quote(a) for a in args[2:]))
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            cwd=str(BASE), start_new_session=True)
    with lock:
        procs[name] = proc
    status_cache.pop(name, None)

    def pump():
        for line in proc.stdout:
            log(name, line)
        log(name, f"— capture process ended (code {proc.wait()})")
    threading.Thread(target=pump, daemon=True).start()
    return {"ok": True}


def mode_orb(name):
    status_cache.pop(name, None)
    dest, iface, _ = target(name)
    log(name, "↺ Back to Orb mode requested")
    r = subprocess.run(["/bin/bash", str(NPR), "restore", dest, "-i", iface], capture_output=True, text=True, timeout=60)
    for line in (r.stdout + r.stderr).splitlines():
        log(name, line)
    return {"ok": r.returncode == 0}


# --------------------------------------------------------------------------- #
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if "json" in ctype or "html" in ctype else ""))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        try:
            if u.path == "/":
                return self.send(200, PAGE.encode(), "text/html")
            if u.path == "/api/sensors":
                return self.send(200, {"sensors": [{"name": n, "host": s.get("host", n), "site": s.get("site", "")}
                                                   for n, s in sensors().items()]})
            if u.path == "/api/status":
                return self.send(200, status(q["sensor"]))
            if u.path == "/api/scan":
                return self.send(200, scan(q["sensor"]))
            if u.path == "/api/log":
                with lock:
                    return self.send(200, {"lines": list(logs.get(q["sensor"], []))[-60:]})
        except Exception as e:
            return self.send(400, {"ok": False, "error": str(e)})
        self.send(404, {"ok": False})

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            p = json.loads(self.rfile.read(n) or b"{}")
            if self.headers.get("Origin") not in (None, f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"):
                return self.send(403, {"ok": False, "error": "origin refused"})
            if u.path == "/api/capture":
                try:
                    return self.send(200, start_capture(p["sensor"], p))
                except Exception as e:
                    log(p.get("sensor", "?"), f"✘ Capture refused: {e}")
                    raise
            if u.path == "/api/orb":
                return self.send(200, mode_orb(p["sensor"]))
        except Exception as e:
            return self.send(400, {"ok": False, "error": str(e)})
        self.send(404, {"ok": False})


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NanoPi (recycled) + Orb Sensor</title>
<style>
:root{--bg:#15171b;--card:#1f2228;--line:#2e333b;--txt:#e6e8eb;--mut:#8c96a3;--brass:#c9a227;--ok:#1fa88a;--warn:#e0a526;--bad:#d64545}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif}
header{display:flex;align-items:center;gap:16px;padding:18px 28px;border-bottom:1px solid var(--line)}
h1{font-size:18px;margin:0;font-weight:650}h1 span{color:var(--brass)}
select,input,button{font:inherit;color:var(--txt);background:#262a31;border:1px solid var(--line);border-radius:8px;padding:7px 10px}
button{cursor:pointer;font-weight:600}button:disabled{opacity:.4;cursor:default}
.pill{margin-left:auto;padding:8px 16px;border-radius:999px;font-weight:700;letter-spacing:.04em}
.pill.orb{background:#123d33;color:#7ff0cf}.pill.cap{background:#4a3a0e;color:#ffd66b}.pill.off{background:#3b1d1f;color:#ff9b9b}
main{display:grid;gap:18px;padding:22px 28px;grid-template-columns:1fr 1.35fr 1fr;
 grid-template-areas:"link screen sys" "mode screen aps" "log log log"}
#c-link{grid-area:link}#c-sys{grid-area:sys}#c-mode{grid-area:mode}#c-aps{grid-area:aps}#c-log{grid-area:log}
#oledcard{grid-area:screen;display:flex;flex-direction:column}
@media(max-width:1150px){main{grid-template-columns:1fr;grid-template-areas:"screen" "link" "sys" "mode" "aps" "log"}}
.bezel{flex:1;display:flex;align-items:center;justify-content:center;background:#0b0c0e;border-radius:12px;padding:18px;box-shadow:inset 0 0 0 2px #000}
#oledimg{width:100%;max-width:640px;aspect-ratio:2/1;image-rendering:pixelated;display:block;filter:drop-shadow(0 0 3px #9ecbff55)}
.btns{display:flex;justify-content:flex-end;gap:14px;margin-top:14px}.btns i{width:18px;height:18px;border-radius:50%;background:radial-gradient(circle at 35% 35%,#f3d77a,#b08a1f)}
#nooled{color:var(--mut);text-align:center;padding:30px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin:0 0 12px}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 12px}.kv div:nth-child(odd){color:var(--mut)}
.big{font-size:30px;font-weight:700}.mut{color:var(--mut)}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:10px}
.go{background:var(--brass);color:#1c1f24;border:0}.orbbtn{background:var(--ok);color:#06231c;border:0}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 6px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:500}tr.ap:hover{background:#2a2f37;cursor:pointer}
.b6{color:#b99cff}.b5{color:#7fc8ff}.b24{color:#ffb37a}
pre{margin:0;max-height:260px;overflow:auto;font:12px/1.4 ui-monospace,Menlo,monospace;color:#c7cdd5;white-space:pre-wrap}
.err{color:var(--bad)}.wide{grid-column:1/-1}
</style></head><body>
<header><h1>NanoPi (recycled) <span>+</span> Orb Sensor</h1>
<select id="sensor"></select><span class="mut" id="upd"></span>
<div id="pill" class="pill off">—</div></header>
<main>
 <section class="card" id="c-link"><h2>Wi-Fi link</h2><div id="link" class="kv"></div></section>
 <section class="card" id="oledcard"><h2>Sensor screen</h2>
  <div class="bezel"><img id="oledimg" alt="Sensor screen" style="display:none"><div id="nooled">No virtual screen on this sensor.<br>
  To enable it: <code>ssh root@IP 'bash -s -- both' &lt; install-oled.sh</code></div></div>
  <div class="btns"><i></i><i></i><i></i></div></section>
 <section class="card" id="c-sys"><h2>Sensor</h2><div id="sys" class="kv"></div></section>
 <section class="card" id="c-mode"><h2>Mode</h2>
  <div class="row"><button class="orbbtn" id="orb">Orb mode (client)</button><span class="mut">stops any capture and reconnects Wi-Fi</span></div>
  <div class="row"><label>Band <select id="band"><option>2.4</option><option selected>5</option><option>6</option></select></label>
   <label>Channel <input id="ch" type="number" min="1" max="233" value="36" style="width:80px"></label>
   <label>Width <select id="width"><option>20</option><option>40</option><option>80</option><option>160</option></select></label></div>
  <div class="row"><label>Filter <select id="filter"><option value="">All</option><option value="type mgt">Management</option>
   <option value="type mgt subtype beacon">Beacons</option><option value="type mgt subtype probe-req or type mgt subtype probe-resp">Probes</option>
   <option value="type mgt subtype assoc-req or type mgt subtype reassoc-req or type mgt subtype auth or type mgt subtype deauth or type mgt subtype disassoc or ether proto 0x888e">Connections + EAPOL</option>
   <option value="type ctl">Control</option><option value="type data">Data</option></select></label>
   <label><input type="checkbox" id="snap"> Headers only</label></div>
  <div class="row"><label>Output <select id="out"><option value="ws">Live Wireshark</option><option value="file">.pcap file</option></select></label>
   <label>Duration <input id="dur" type="number" min="0" value="0" style="width:70px"> s</label>
   <button class="go" id="cap">Capture mode ▶</button></div>
  <div id="msg" class="mut"></div></section>
 <section class="card" id="c-aps"><h2>Nearby APs <button id="scan" style="float:right;padding:3px 10px">Scan</button></h2>
  <div class="mut" id="scanmsg">Click "Scan" (in Orb mode), then a row to set the capture channel.</div>
  <table id="aps"></table></section>
 <section class="card" id="c-log"><h2>Log</h2><pre id="log"></pre></section>
</main>
<script>
const $=id=>document.getElementById(id);let S="",OLED="",TOUCHED=false;
setInterval(()=>{if(OLED&&!document.hidden)$("oledimg").src=OLED+"/screen.png?"+Date.now()},1500);
const api=(p,b)=>fetch(p,b?{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(b)}:{}).then(r=>r.json());
function kv(el,rows){el.innerHTML=rows.map(([k,v])=>`<div>${k}</div><div>${v??"—"}</div>`).join("")}
async function load(){const r=await api("/api/sensors");$("sensor").innerHTML=r.sensors.map(s=>`<option value="${s.name}">${s.name} · ${s.host}</option>`).join("");
 let saved="";try{saved=localStorage.getItem("npr.sensor")||""}catch(e){}
 if(saved&&r.sensors.some(s=>s.name===saved))$("sensor").value=saved;S=$("sensor").value;refresh();}
async function refresh(){if(!S)return;const d=await api("/api/status?sensor="+encodeURIComponent(S));
 $("upd").textContent="updated "+new Date().toLocaleTimeString();
 if(!d.ok){$("pill").className="pill off";$("pill").textContent="UNREACHABLE";kv($("link"),[["Error",`<span class=err>${d.error}</span>`]]);return;}
 const cap=d.mode==="monitor";
 if(!cap&&!TOUCHED&&d.freq){const f=+d.freq;$("band").value=f<3000?"2.4":f<5925?"5":"6";$("ch").value=d.chan;}$("pill").className="pill "+(cap?"cap":"orb");$("pill").textContent=cap?"CAPTURE MODE":"ORB MODE";
 $("cap").disabled=cap;
 kv($("link"),cap?[["Mode","monitor"],["Channel",`${d.chan} · ${d.freq} MHz · ${d.width} MHz`],["Since",d.capture||"—"],["Orb","measuring over Ethernet"]]:
  [["SSID",`<span class=big>${d.ssid||"—"}</span>`],["BSSID",d.bssid],["Channel",`${d.chan} · ${d.freq} MHz · ${d.width} MHz`],["RSSI",d.signal?d.signal+" dBm":"—"],["RX",d.rx],["TX",d.tx],["IP Wi-Fi",d.ip]]);
 kv($("sys"),[["Host",d.host],["Orb",d.orb],["Wi-Fi client",d.client],["Screen",d.oled],["CPU temp",d.temp+" °C"],["Load",d.load],["Uptime",d.uptime]]);
 OLED=d.oled_url||"";$("oledimg").style.display=OLED?"":"none";$("nooled").style.display=OLED?"none":"";
 const l=await api("/api/log?sensor="+encodeURIComponent(S));$("log").textContent=l.lines.join("\n");$("log").scrollTop=1e6;}
$("sensor").onchange=()=>{S=$("sensor").value;TOUCHED=false;try{localStorage.setItem("npr.sensor",S)}catch(e){};OLED="";$("oledimg").style.display="none";refresh()};
$("orb").onclick=async()=>{$("msg").textContent="Back to Orb mode…";const r=await api("/api/orb",{sensor:S});$("msg").textContent=r.ok?"Orb mode restored.":"Failed: "+(r.error||"see the log");refresh();};
$("cap").onclick=async()=>{$("msg").textContent="Starting capture…";
 const r=await api("/api/capture",{sensor:S,band:$("band").value,ch:+$("ch").value,width:+$("width").value,filter:$("filter").value,snap:$("snap").checked,to_file:$("out").value==="file",duration:+$("dur").value});
 $("msg").innerHTML=r.ok?"Capture started — Wireshark is opening (or file in captures/).":`<span class=err>${r.error}</span>`;setTimeout(refresh,4000);};
$("scan").onclick=async()=>{$("scanmsg").textContent="Scanning (10 to 20 s)…";$("aps").innerHTML="";const r=await api("/api/scan?sensor="+encodeURIComponent(S));
 if(!r.ok){$("scanmsg").innerHTML=`<span class=err>${r.error}</span>`;return;}$("scanmsg").textContent=r.aps.length+" BSS";
 $("aps").innerHTML="<tr><th>SSID</th><th>Band</th><th>Channel</th><th>RSSI</th><th>BSSID</th></tr>"+r.aps.map(a=>{const c=a.band==="6"?"b6":a.band==="5"?"b5":"b24";
  return `<tr class="ap" data-b="${a.band}" data-c="${a.ch}"><td>${a.ssid?a.ssid.replace(/</g,"&lt;"):"<i class=mut>hidden</i>"}</td><td class="${c}">${a.band} GHz</td><td>${a.ch}</td><td>${a.signal}</td><td class=mut>${a.bssid}</td></tr>`}).join("");
 document.querySelectorAll("tr.ap").forEach(tr=>tr.onclick=()=>{TOUCHED=true;$("band").value=tr.dataset.b;$("ch").value=tr.dataset.c;$("msg").textContent=`Set to ${tr.dataset.b} GHz, channel ${tr.dataset.c}.`});};
["band","ch","width"].forEach(id=>$(id).addEventListener("input",()=>TOUCHED=true));
load();setInterval(()=>{if(!document.hidden)refresh()},5000);
</script></body></html>"""


if __name__ == "__main__":
    if not NPR.exists():
        raise SystemExit(f"nanopi-recycled.sh not found next to {__file__}")
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"NanoPi (recycled) + Orb Sensor — http://127.0.0.1:{PORT}  (Ctrl+C to stop)")
    srv.serve_forever()
