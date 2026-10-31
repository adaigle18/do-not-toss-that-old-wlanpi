#!/usr/bin/env python3
"""
report2xlsx.py — Turn a sensor-diag.sh text report into a formatted workbook
(.xlsx) that opens cleanly in Apple Numbers, Excel or LibreOffice.

Usage:
    python3 report2xlsx.py reports/sensor-neo2-01_20261031-1253.txt [out.xlsx]

Works with the English and French reports. Requires openpyxl
(pip install openpyxl, or .venv/bin/pip install openpyxl).
"""
import re
import sys
from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

# ---------------------------------------------------------------- parsing
ANSI = re.compile(r"\x1b\[[0-9;]*m")
SECTIONS = {
    "health": ("SANTÉ DU CAPTEUR", "SENSOR HEALTH"),
    "network": ("RÉSEAU", "NETWORK"),
    "wifi": ("LIEN WI-FI", "WI-FI LINK"),
    "scan": ("SCAN DES AP VOISINS", "NEARBY APs", "NEARBY APS"),
    "conn": ("TESTS DE CONNECTIVITÉ", "CONNECTIVITY"),
    "iperf": ("IPERF3",),
    "orb": ("ORB",),
}
KV = re.compile(r"^ {2}(\S.*?)\s{2,}(\S.*)$")
MAC = r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}"
AP = re.compile(
    rf"^\s+(?P<ssid>.*?)\s+(?P<bssid>{MAC})\s+(?P<band>[\d.]+ GHz)\s+(?P<ch>\d+)\s+"
    r"(?P<width>\d+ MHz\??|n/a|\S+)\s+(?P<rssi>-?[\d.]+)\s+(?P<sec>\S+)\s*(?P<assoc>●)?\s*$")
PING_HDR = re.compile(r"^\s+ping\s+(\S+)")
PING_LOSS = re.compile(r"(\d+) packets transmitted, (\d+) received.*?([\d.]+)% packet loss")
PING_RTT = re.compile(r"= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms")
HOP = re.compile(r"^\s+(\d+)\??:\s+(\S+(?: \S+)?)\s*(?:([\d.]+)ms)?")


def decode_ssid(s: str) -> str:
    if "\\x" not in s:
        return s
    try:
        return s.encode("latin-1").decode("unicode_escape").encode("latin-1").decode("utf-8")
    except Exception:
        return s


def section_key(title: str):
    t = title.upper()
    for key, names in SECTIONS.items():
        if any(t.startswith(n) for n in names):
            return key
    return None


def parse(text: str) -> dict:
    lines = [ANSI.sub("", l.rstrip("\n")) for l in text.splitlines()]
    r = {"title": "", "date": "", "kv": {}, "ifaces": [], "routes": [], "aps": [],
         "pings": [], "dns": "", "hops": [], "orb_logs": [], "iperf": []}
    head = [l.strip("║ ").strip() for l in lines[:4] if "║" in l]
    if head:
        r["title"] = head[0]
        r["date"] = head[1] if len(head) > 1 else ""
    sec, sub, ping = None, None, None
    for l in lines:
        m = re.match(r"^══ (.+?)\s*$", l)
        if m:
            sec, sub = section_key(m.group(1)), None
            r["kv"].setdefault(sec, [])
            continue
        if sec is None or not l.strip():
            continue
        s = l.strip()
        # sub-headings inside a section
        if s in ("Interfaces", "Routes", "Station dump") or s.startswith(("Chemin vers", "Path to")) \
                or s.startswith(("Derniers journaux", "Recent logs", "Last logs")):
            sub = s
            continue
        if sec == "network" and sub == "Interfaces" and l.startswith("    "):
            parts = s.split()
            r["ifaces"].append([parts[0], parts[1] if len(parts) > 1 else "", " ".join(parts[2:])])
            continue
        if sec == "network" and sub == "Routes" and l.startswith("    "):
            r["routes"].append(s)
            continue
        if sec == "scan":
            m = AP.match(l)
            if m:
                d = m.groupdict()
                r["aps"].append([decode_ssid(d["ssid"].strip()), d["bssid"], d["band"], int(d["ch"]),
                                 d["width"], float(d["rssi"]), d["sec"], "●" if d["assoc"] else ""])
                continue
        if sec == "conn":
            m = PING_HDR.match(l)
            if m:
                ping = {"target": m.group(1), "sent": None, "recv": None, "loss": None,
                        "min": None, "avg": None, "max": None, "mdev": None}
                r["pings"].append(ping)
                continue
            m = PING_LOSS.search(l)
            if m and ping:
                ping.update(sent=int(m.group(1)), recv=int(m.group(2)), loss=float(m.group(3)) / 100)
                continue
            m = PING_RTT.search(l)
            if m and ping:
                ping.update(min=float(m.group(1)), avg=float(m.group(2)),
                            max=float(m.group(3)), mdev=float(m.group(4)))
                continue
            if sub and sub.startswith(("Chemin", "Path")):
                m = HOP.match(l)
                if m and "LOCALHOST" not in l:
                    r["hops"].append([int(m.group(1)), m.group(2).replace("no reply", "—"),
                                      float(m.group(3)) if m.group(3) else None])
                continue
        if sec == "orb" and sub and sub.startswith(("Derniers", "Recent", "Last")) and l.startswith("    "):
            r["orb_logs"].append(s)
            continue
        if sec == "iperf":
            r["iperf"].append(s)
            continue
        m = KV.match(l)
        if m:
            r["kv"][sec].append((m.group(1).strip(), m.group(2).strip()))
            if sec == "conn" and m.group(1).startswith("DNS"):
                r["dns"] = f"{m.group(1).strip()}  {m.group(2).strip()}"
    return r


# ---------------------------------------------------------------- styling
FONT = "Arial"
NAVY, TEAL, GREY = "1F2A44", "0F766E", "F2F4F7"
GOOD, WARN, BAD = "D1F2E0", "FFF1C2", "F9D3D0"
F_TITLE = Font(name=FONT, size=18, bold=True, color=NAVY)
F_SUB = Font(name=FONT, size=11, color="6B7280")
F_H = Font(name=FONT, size=11, bold=True, color="FFFFFF")
F_SEC = Font(name=FONT, size=12, bold=True, color=TEAL)
F_KEY = Font(name=FONT, size=11, color="4B5563")
F_VAL = Font(name=FONT, size=11, color="111827")
F_BIG = Font(name=FONT, size=15, bold=True, color=NAVY)
FILL_H = PatternFill("solid", fgColor=NAVY)
FILL_ALT = PatternFill("solid", fgColor=GREY)
FILL = {k: PatternFill("solid", fgColor=v) for k, v in (("good", GOOD), ("warn", WARN), ("bad", BAD))}
THIN = Side(style="thin", color="D0D5DD")
BOX = Border(bottom=THIN)
WRAP = Alignment(wrap_text=True, vertical="top")
L = {
    "fr": dict(summary="Résumé", wifi="Wi-Fi", aps="AP voisins", conn="Connectivité", net="Réseau",
               orb="Orb", report="Rapport de diagnostic", key="Indicateur", val="Valeur", status="État",
               ssid="SSID", bssid="BSSID", band="Bande", ch="Canal", width="Largeur", rssi="RSSI (dBm)",
               sec="Sécurité", assoc="Associé", target="Cible", sent="Envoyés", recv="Reçus",
               loss="Perte", hop="Saut", host="Hôte", rtt="RTT (ms)", iface="Interface", state="État",
               addr="Adresses", routes="Routes", logs="Journaux Orb récents", counts="AP par bande",
               total="Total", hidden="SSID cachés", strong="AP ≥ -67 dBm", legend="Légende",
               lg="Bon", lw="À surveiller", lb="Problème", source="Source : rapport texte "),
    "en": dict(summary="Summary", wifi="Wi-Fi", aps="Nearby APs", conn="Connectivity", net="Network",
               orb="Orb", report="Diagnostic report", key="Metric", val="Value", status="Status",
               ssid="SSID", bssid="BSSID", band="Band", ch="Channel", width="Width", rssi="RSSI (dBm)",
               sec="Security", assoc="Associated", target="Target", sent="Sent", recv="Received",
               loss="Loss", hop="Hop", host="Host", rtt="RTT (ms)", iface="Interface", state="State",
               addr="Addresses", routes="Routes", logs="Recent Orb logs", counts="APs per band",
               total="Total", hidden="Hidden SSIDs", strong="APs ≥ -67 dBm", legend="Legend",
               lg="Good", lw="Watch", lb="Problem", source="Source: text report "),
}


def num(v):
    m = re.search(r"-?\d+(?:\.\d+)?", v or "")
    return float(m.group()) if m else None


def grade(key: str, val: str):
    k, n = key.lower(), num(val)
    if n is None:
        return None
    if k.startswith("rssi") or "signal" in k:
        return "good" if n >= -67 else "warn" if n >= -75 else "bad"
    if "retry" in k:
        return "good" if n < 10 else "warn" if n < 20 else "bad"
    if "beacon" in k:
        return "good" if n == 0 else "warn" if n < 5 else "bad"
    if "temp" in k:
        return "good" if n < 60 else "warn" if n < 75 else "bad"
    if k.startswith(("mémoire", "memory", "disque", "disk")):
        p = re.search(r"\((\d+)%\)", val)
        if p:
            p = int(p.group(1))
            return "good" if p < 70 else "warn" if p < 90 else "bad"
    return None


def header(ws, row, labels, col=1):
    for i, t in enumerate(labels):
        c = ws.cell(row=row, column=col + i, value=t)
        c.font, c.fill = F_H, FILL_H
        c.alignment = Alignment(vertical="center")
    ws.row_dimensions[row].height = 22


def kv_block(ws, row, title, items, lang):
    ws.cell(row=row, column=1, value=title).font = F_SEC
    row += 1
    for k, v in items:
        ws.cell(row=row, column=1, value=k).font = F_KEY
        c = ws.cell(row=row, column=2, value=v)
        c.font, c.alignment = F_VAL, WRAP
        g = grade(k, v)
        if g:
            c.fill = FILL[g]
        for col in (1, 2):
            ws.cell(row=row, column=col).border = BOX
        row += 1
    return row + 1


def widths(ws, w):
    for i, x in enumerate(w, 1):
        ws.column_dimensions[get_column_letter(i)].width = x


def build(r: dict, src: str, out: Path):
    fr = any(k in r["kv"] for k in ("health",)) and any(
        k == "Hôte" for k, _ in r["kv"].get("health", []))
    T = L["fr" if fr else "en"]
    kv = {k: dict(v) for k, v in r["kv"].items() if k}
    wb = Workbook()

    # ---- Summary
    ws = wb.active
    ws.title = T["summary"]
    ws.sheet_view.showGridLines = False
    host = kv.get("health", {}).get("Hôte") or kv.get("health", {}).get("Host") or ""
    ws["A1"] = f"{T['report']} — {host}"
    ws["A1"].font = F_TITLE
    ws["A2"] = r["date"]
    ws["A2"].font = F_SUB
    wifi = kv.get("wifi", {})

    def pick(d, *names):
        for n in names:
            if n in d:
                return d[n]
        return ""
    band_lbl = "Bande / canal" if fr else "Band / channel"
    tiles = [
        ("SSID", pick(wifi, "SSID")),
        (band_lbl, pick(wifi, "Bande / canal", "Band / channel")),
        ("RSSI", pick(wifi, "RSSI")),
        ("Orb", pick(kv.get("orb", {}), "Service")),
    ]
    for i, (label, value) in enumerate(tiles):
        col = 1 + i
        ws.cell(row=4, column=col, value=label).font = F_KEY
        v = ws.cell(row=5, column=col, value=value)
        v.font = F_BIG
        if label == "RSSI":
            g = grade("rssi", value)
        elif label == "Orb":
            g = "good" if value == "active" else ("bad" if value else None)
        else:
            g = None
        if g:
            v.fill = FILL[g]
    ws.row_dimensions[5].height = 30

    row = 7
    row = kv_block(ws, row, T["wifi"], [(k, v) for k, v in r["kv"].get("wifi", []) if k not in ("Débit attendu", "Expected throughput")], T)
    row = kv_block(ws, row, "Capteur" if fr else "Sensor", r["kv"].get("health", []), T)

    # legend
    ws.cell(row=row, column=1, value=T["legend"]).font = F_SEC
    for i, (k, t) in enumerate((("good", T["lg"]), ("warn", T["lw"]), ("bad", T["lb"]))):
        c = ws.cell(row=row + 1 + i, column=1, value=t)
        c.fill, c.font = FILL[k], F_VAL
    ws.cell(row=row + 5, column=1, value=T["source"] + src).font = F_SUB
    widths(ws, [24, 46, 16, 14])

    # ---- Nearby APs
    wa = wb.create_sheet(T["aps"])
    wa.sheet_view.showGridLines = False
    cols = [T["ssid"], T["bssid"], T["band"], T["ch"], T["width"], T["rssi"], T["sec"], T["assoc"]]
    header(wa, 1, cols)
    for i, ap in enumerate(sorted(r["aps"], key=lambda a: -a[5]), start=2):
        for j, v in enumerate(ap, start=1):
            c = wa.cell(row=i, column=j, value=v)
            c.font = F_VAL
            if i % 2 == 0:
                c.fill = FILL_ALT
        for j in (3, 4, 5, 6, 8):
            wa.cell(row=i, column=j).alignment = Alignment(horizontal="center")
        g = grade("rssi", str(ap[5]))
        wa.cell(row=i, column=6).fill = FILL[g]
        if ap[7]:
            for j in range(1, 9):
                wa.cell(row=i, column=j).font = Font(name=FONT, size=11, bold=True, color=TEAL)
    last = max(2, len(r["aps"]) + 1)
    wa.freeze_panes = "A2"
    wa.auto_filter.ref = f"A1:H{last}"
    # band counts (live formulas)
    wa["J1"], wa["K1"] = T["counts"], T["total"]
    header(wa, 1, [T["counts"], T["total"]], col=10)
    for i, b in enumerate(("2.4 GHz", "5 GHz", "6 GHz"), start=2):
        wa.cell(row=i, column=10, value=b).font = F_VAL
        wa.cell(row=i, column=11, value=f'=COUNTIF($C$2:$C${last},J{i})').font = F_VAL
    wa.cell(row=5, column=10, value=T["total"]).font = Font(name=FONT, size=11, bold=True)
    wa.cell(row=5, column=11, value=f"=COUNTA($B$2:$B${last})").font = Font(name=FONT, size=11, bold=True)
    hidden = "(caché)" if fr else "(hidden)"
    wa.cell(row=6, column=10, value=T["hidden"]).font = F_VAL
    wa.cell(row=6, column=11, value=f'=COUNTIF($A$2:$A${last},"{hidden}")').font = F_VAL
    wa.cell(row=7, column=10, value=T["strong"]).font = F_VAL
    wa.cell(row=7, column=11, value=f'=COUNTIF($F$2:$F${last},">=-67")').font = F_VAL
    widths(wa, [26, 20, 10, 8, 10, 12, 11, 10, 3, 18, 9])

    # ---- Connectivity
    wc = wb.create_sheet(T["conn"])
    wc.sheet_view.showGridLines = False
    header(wc, 1, [T["target"], T["sent"], T["recv"], T["loss"], "min (ms)", "avg (ms)", "max (ms)", "jitter (ms)"])
    for i, p in enumerate(r["pings"], start=2):
        vals = [p["target"], p["sent"], p["recv"], f"=IF(B{i}>0,1-C{i}/B{i},\"\")",
                p["min"], p["avg"], p["max"], p["mdev"]]
        for j, v in enumerate(vals, start=1):
            c = wc.cell(row=i, column=j, value=v)
            c.font = F_VAL
        wc.cell(row=i, column=4).number_format = "0%"
        wc.cell(row=i, column=4).fill = FILL["good" if (p["loss"] or 0) == 0 else "warn" if p["loss"] < 0.05 else "bad"]
        avg = p["avg"] or 0
        wc.cell(row=i, column=6).fill = FILL["good" if avg < 30 else "warn" if avg < 80 else "bad"]
        for j in (5, 6, 7, 8):
            wc.cell(row=i, column=j).number_format = "0.0"
    row = len(r["pings"]) + 3
    if r["dns"]:
        wc.cell(row=row, column=1, value=r["dns"]).font = F_VAL
        row += 2
    if r["hops"]:
        header(wc, row, [T["hop"], T["host"], T["rtt"]])
        for i, h in enumerate(r["hops"], start=row + 1):
            for j, v in enumerate(h, start=1):
                c = wc.cell(row=i, column=j, value=v)
                c.font = F_VAL
            wc.cell(row=i, column=3).number_format = "0.0"
    if r["iperf"]:
        row = row + len(r["hops"]) + 3
        wc.cell(row=row, column=1, value="iperf3").font = F_SEC
        for i, l in enumerate(r["iperf"], start=row + 1):
            wc.cell(row=i, column=1, value=l).font = F_VAL
    widths(wc, [22, 26, 12, 10, 10, 10, 10, 11])

    # ---- Network
    wn = wb.create_sheet(T["net"])
    wn.sheet_view.showGridLines = False
    header(wn, 1, [T["iface"], T["state"], T["addr"]])
    for i, f in enumerate(r["ifaces"], start=2):
        for j, v in enumerate(f, start=1):
            c = wn.cell(row=i, column=j, value=v)
            c.font, c.alignment = F_VAL, WRAP
    row = len(r["ifaces"]) + 3
    header(wn, row, [T["routes"]])
    for i, l in enumerate(r["routes"], start=row + 1):
        wn.cell(row=i, column=1, value=l).font = F_VAL
    row = row + len(r["routes"]) + 2
    kv_block(wn, row, T["net"], r["kv"].get("network", []), T)
    widths(wn, [70, 12, 90])

    # ---- Orb
    wo = wb.create_sheet(T["orb"])
    wo.sheet_view.showGridLines = False
    row = kv_block(wo, 1, "Orb", r["kv"].get("orb", []), T)
    wo.cell(row=row, column=1, value=T["logs"]).font = F_SEC
    for i, l in enumerate(r["orb_logs"], start=row + 1):
        m = re.search(r"level=(\w+) msg=(.*)$", l)
        ts = l.split()[0]
        lvl = m.group(1) if m else ""
        wo.cell(row=i, column=1, value=ts).font = F_KEY
        c = wo.cell(row=i, column=2, value=f"{lvl}  {m.group(2)}" if m else l)
        c.font = F_VAL
        if lvl in ("WARN", "ERROR"):
            c.fill = FILL["warn" if lvl == "WARN" else "bad"]
    widths(wo, [28, 120])

    for sh in wb.worksheets:
        sh.sheet_properties.tabColor = TEAL if sh.title == T["summary"] else NAVY
    wb.save(out)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".xlsx")
    r = parse(src.read_text(encoding="utf-8", errors="replace"))
    build(r, src.name, out)
    print(f"✔ {out}  ({len(r['aps'])} APs, {len(r['pings'])} pings, {len(r['hops'])} hops)")


if __name__ == "__main__":
    main()
