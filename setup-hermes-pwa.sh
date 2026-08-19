#!/usr/bin/env bash
# Hermes PWA setup: web terminal (tmux + ttyd) + installable PWA shell,
# fronted by tailscale serve (HTTPS). Idempotent.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root: curl ... | sudo bash"; exit 1; }

HOST_DNS=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
[ -n "$HOST_DNS" ] || { echo "could not determine tailscale DNS name"; exit 1; }
echo "tailnet name: $HOST_DNS"

PWA_DIR=/root/hermes-pwa
TTYD_PORT=8001
SHELL_PORT=8000
TTYD_HTTPS=8443

echo "[1/6] dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq tmux curl >/dev/null
if ! command -v ttyd >/dev/null 2>&1; then
  apt-get install -y -qq ttyd >/dev/null 2>&1 || {
    echo "ttyd not in apt, fetching static binary"
    curl -fsSL -o /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64
    chmod +x /usr/local/bin/ttyd
  }
fi
TTYD_BIN=$(command -v ttyd)
HERMES_BIN=$(command -v hermes || true)
[ -n "$HERMES_BIN" ] || { echo "hermes command not found in PATH"; exit 1; }
echo "ttyd: $TTYD_BIN | hermes: $HERMES_BIN"

echo "[2/6] PWA shell in $PWA_DIR"
mkdir -p "$PWA_DIR"

python3 - <<'PY'
import struct, zlib
def png(path, size, rgb):
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    row = b"\x00" + bytes(rgb) * size
    idat = zlib.compress(row * size)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))
png("/root/hermes-pwa/icon-192.png", 192, (13, 17, 23))
png("/root/hermes-pwa/icon-512.png", 512, (13, 17, 23))
PY

cat > "$PWA_DIR/manifest.json" <<'EOF'
{
  "id": "./",
  "name": "Hermes Agent",
  "short_name": "Hermes",
  "start_url": "./",
  "scope": "./",
  "display": "standalone",
  "background_color": "#0d1117",
  "theme_color": "#0d1117",
  "icons": [
    { "src": "./icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "./icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
EOF

cat > "$PWA_DIR/sw.js" <<'EOF'
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
EOF

cat > "$PWA_DIR/index.html" <<EOF
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="mobile-web-app-capable" content="yes">
<title>Hermes Agent</title>
<link rel="manifest" href="./manifest.json">
<style>html,body{margin:0;height:100%;background:#0d1117;overflow:hidden}iframe{border:0;width:100%;height:100%}</style>
</head>
<body>
<iframe src="https://$HOST_DNS:$TTYD_HTTPS" allow="clipboard-read; clipboard-write"></iframe>
<script>if("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(()=>{});</script>
</body>
</html>
EOF

echo "[3/6] systemd units"
cat > /etc/systemd/system/hermes-ttyd.service <<EOF
[Unit]
Description=Hermes web terminal (ttyd + tmux)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$TTYD_BIN --writable -i lo -p $TTYD_PORT tmux new-session -A -s hermes $HERMES_BIN
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hermes-pwa.service <<EOF
[Unit]
Description=Hermes PWA shell (static)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 -m http.server $SHELL_PORT --bind 127.0.0.1 --directory $PWA_DIR
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hermes-ttyd hermes-pwa

echo "[4/6] tailscale serve"
tailscale serve reset || true
tailscale serve --bg http://127.0.0.1:$SHELL_PORT
tailscale serve --bg --https=$TTYD_HTTPS http://127.0.0.1:$TTYD_PORT

echo "[5/6] smoke test"
sleep 2
curl -fsS -o /dev/null "http://127.0.0.1:$SHELL_PORT/" && echo "  shell OK (port $SHELL_PORT)"
curl -fsS -o /dev/null "http://127.0.0.1:$TTYD_PORT/" && echo "  ttyd OK (port $TTYD_PORT)"
curl -fsS -o /dev/null "https://$HOST_DNS/" && echo "  https OK"

echo "[6/6] done"
echo
echo "Open https://$HOST_DNS/ on your phone, then: Chrome menu -> Install app / Add to Home screen"
