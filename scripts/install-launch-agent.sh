#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LABEL="${BRIDGE_LABEL:-com.maludex.bridge}"
PLIST="${BRIDGE_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/$LABEL.plist}"
TOKEN_FILE="${BRIDGE_TOKEN_FILE:-$HOME/.codex-iphone-remote-bridge/token}"
HOST="${BRIDGE_HOST:-127.0.0.1}"
PORT="${BRIDGE_PORT:-8765}"
NPM_BIN="$(command -v npm || true)"
NODE_BIN="$(command -v node || true)"

if [ -z "$NPM_BIN" ]; then
  echo "npm was not found. Install Node.js 20 or newer first."
  exit 1
fi

if [ -z "$NODE_BIN" ]; then
  echo "node was not found. Install Node.js 20 or newer first."
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI is required. Install and log in before running maludex."
  exit 1
fi

if [ ! -f package-lock.json ]; then
  echo "package-lock.json is missing; run npm install before installing the LaunchAgent."
  exit 1
fi

npm install
npm run build

umask 077
mkdir -p "$(dirname "$TOKEN_FILE")"
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -base64 32 > "$TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$ROOT_DIR/dist/bridge/src/index.js</string>
    <string>--host</string>
    <string>$HOST</string>
    <string>--port</string>
    <string>$PORT</string>
    <string>--no-qr</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/maludex-bridge.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/maludex-bridge.launchd.err.log</string>
</dict>
</plist>
PLIST

chmod 600 "$PLIST"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  sleep 1
fi

for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    break
  fi
  if [ "$attempt" = "5" ]; then
    echo "Could not bootstrap $LABEL after $attempt attempts." >&2
    exit 1
  fi
  sleep "$attempt"
done
launchctl kickstart -k "gui/$(id -u)/$LABEL"

cat <<EOF
maludex LaunchAgent installed.

Label: $LABEL
Plist: $PLIST
Bridge: ws://$HOST:$PORT
Token file: $TOKEN_FILE

For physical iPhone or off-Wi-Fi access through Tailscale, run:
  ./scripts/configure-tailscale-bridge.sh
EOF
