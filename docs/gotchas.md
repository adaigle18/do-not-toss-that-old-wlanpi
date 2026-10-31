# Gotchas (things that bit me)

**Wrong image for the board.** NEO2 and NEO3 images are not interchangeable. The ex-WLAN Pi is a NEO2 *Black*: use that image.

**Slow or worn microSD cards.** Symptoms are random dpkg failures and endless boots. Use a new A1/A2 card. The scripts run `dpkg --configure -a` to recover interrupted installs.

**netplan + networkd: no `match:` for wifis.** Armbian minimal uses the networkd renderer, which rejects `match:` under `wifis:`. Fix: a systemd `.link` file (`Type=wlan` → `Name=wlan0`).

**Route metrics.** If Ethernet and Wi-Fi are both up, Orb measures whichever has the default route. Wi-Fi gets metric 50 and Ethernet 100, so Orb measures Wi-Fi and you keep managing over Ethernet. Set `dhcp6-overrides` too, or netplan complains.

**ARP flux.** Two NICs on the same subnet means the board answers ARP for the Wi-Fi IP on Ethernet (and vice versa). SSH then dies the moment Wi-Fi goes into monitor mode. Fix: `arp_ignore=1`, `arp_announce=2`, then `arping -U` on the remaining link.

**Monitor mode stuck on the old channel (mt76: mt7921u / mt7925u).** Once the adapter has been associated, `iw dev wlan0 set freq` returns success and `iw info` shows the new channel, but the radio keeps listening on the channel it was connected to. Check the radiotap frequency in your capture, not `iw`. Known mainline mac80211/mt76 issue (monitor vif without a channel context). Workaround: reload the driver (`modprobe -r mt7925u; modprobe mt7925u`) and switch to monitor before any association. `nanopi-recycled.sh` does this automatically.

**"Malformed radiotap v255" in Wireshark.** Those are the host's own outgoing frames. Capture with `tcpdump -Q in`.

**Orb can't see nearby APs.** The service needs `CAP_NET_ADMIN CAP_NET_RAW` (a systemd drop-in installed by `sensor-setup.sh`) *and* the nearby-AP poll interval enabled in Orb settings.

**sshd `MaxStartups`.** A dashboard that opens a new SSH connection every second gets refused. Fix: SSH ControlMaster, plus a short status cache.

**bash history expansion.** A `!` in a Wi-Fi password breaks `echo "..."` in an interactive shell. The provisioning script reads the PSK with a hidden prompt instead.

**IP conflicts.** If a sensor "disappears", check for a duplicate IP on the LAN before blaming the board. Use DHCP reservations when you can.

**Heavy dbus hang on reboot.** On a freshly broken install, `sync; reboot -f` beats waiting.
