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
