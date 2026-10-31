#!/bin/bash
# Rebuild ../install-oled.sh after editing oled-status.py
cd "$(dirname "$0")"
{ cat install-oled.head.sh; cat oled-status.py; cat install-oled.tail.sh; } > ../install-oled.sh
chmod +x ../install-oled.sh && bash -n ../install-oled.sh && echo "install-oled.sh rebuilt"
