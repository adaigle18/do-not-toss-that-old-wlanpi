# USB Wi-Fi adapters

What matters for this project: a **mainline Linux driver** (no DKMS), **monitor mode**, and a decent **managed-mode** experience for Orb. On a NEO2/NEO3, USB 2.0 caps throughput around 300 Mb/s anyway, so a 2×2 Wi-Fi 5/6 adapter is plenty.

| Adapter | Chipset / driver | Bands | Client (Orb) | Monitor | Notes |
|---|---|---|---|---|---|
| Netgear A9000 | MediaTek MT7925U / `mt7925u` | 2.4 / 5 / 6 GHz (Wi-Fi 7) | ✅ | ✅ 2.4 / 5 / 6 GHz | Monitor mode only retunes after a driver reload (mt76 bug, handled automatically by `nanopi-recycled.sh`). Verified: 88 beacons from a 6 GHz AP on ch 197 in 10 s. Occasional boot probe error `-110`: replug or reboot. |
| Netgear A6200 | Broadcom | 2.4 / 5 GHz | ❌ | ❌ | No usable mainline driver in this setup. Skip it. |
| Linksys (USB, Wi-Fi 5) | check with `lsusb` | 2.4 / 5 GHz | ✅ | ✅ | Worked as a client on the NEO2. Exact chipset to be documented. |

✅ works · ⚠️ partial · ❌ no

Check your exact model's chipset with `lsusb` and `iw list` before buying. Revisions of the same product name sometimes change chipsets.

## Tips

- **Name pinning**: `sensor-setup.sh` installs a systemd `.link` file so any USB Wi-Fi adapter becomes `wlan0`. Swap adapters without touching netplan.
- **Power save** is disabled by a udev rule, because it hurts latency scores.
- **Regulatory domain** is set via `cfg80211.ieee80211_regdom=` in `armbianEnv.txt`. Without it you may be stuck on world rules (no 6 GHz, low TX power).
- **6 GHz** requires both a 6 GHz-capable adapter and a regdomain that allows it.
- Report your results! PRs adding rows to this table are very welcome.
