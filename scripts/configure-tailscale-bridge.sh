#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LABEL="${BRIDGE_LABEL:-com.maludex.bridge}"
PLIST="${BRIDGE_LAUNCH_AGENT:-$HOME/Library/LaunchAgents/$LABEL.plist}"
TOKEN_FILE="${BRIDGE_TOKEN_FILE:-$HOME/.codex-iphone-remote-bridge/token}"
PORT="${BRIDGE_PORT:-8765}"
QR_FILE="${BRIDGE_QR_FILE:-/tmp/maludex-pairing.png}"
BRIDGE_NAME="${BRIDGE_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"

find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return
  fi

  for candidate in \
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale" \
    "/Applications/Tailscale.app/Contents/MacOS/tailscale"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

tailscale_ip_from_ifconfig() {
  ifconfig | awk '
    /inet 100\./ {
      split($2, octets, ".")
      if (octets[2] >= 64 && octets[2] <= 127) {
        print $2
        exit
      }
    }
  '
}

TAILSCALE_BIN="$(find_tailscale || true)"
if [ -z "$TAILSCALE_BIN" ]; then
  cat <<'EOF'
Tailscale is not installed yet.

Install it on this Mac, sign in, and enable the VPN configuration:
  https://tailscale.com/download/mac

Then run this script again.
EOF
  open "https://tailscale.com/download/mac" >/dev/null 2>&1 || true
  exit 1
fi

TAILSCALE_IP="$("$TAILSCALE_BIN" ip -4 2>/dev/null | head -n 1 || true)"
if [ -z "$TAILSCALE_IP" ]; then
  TAILSCALE_IP="$(tailscale_ip_from_ifconfig || true)"
fi

if [[ ! "$TAILSCALE_IP" =~ ^100\.([6-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  cat <<EOF
Could not find a Mac Tailscale IPv4 address.

Open Tailscale, sign in on this Mac, enable the VPN, and run this script again.
Detected value: ${TAILSCALE_IP:-<none>}
EOF
  open -a Tailscale >/dev/null 2>&1 || true
  exit 1
fi

if [ ! -f "$TOKEN_FILE" ]; then
  echo "Token file does not exist: $TOKEN_FILE"
  echo "Run ./scripts/setup-local.sh or start the bridge once to create it."
  exit 1
fi

TOKEN_PERMS="$(stat -f "%Lp" "$TOKEN_FILE")"
if [ "$TOKEN_PERMS" != "600" ]; then
  echo "Refusing to use token file with permissions $TOKEN_PERMS: $TOKEN_FILE"
  echo "Fix with: chmod 600 \"$TOKEN_FILE\""
  exit 1
fi

if [ ! -f "$PLIST" ]; then
  echo "LaunchAgent plist does not exist: $PLIST"
  echo "Run ./scripts/install-launch-agent.sh first, then run this script again."
  exit 1
fi

HOST_INDEX=""
PORT_INDEX=""
ARG_COUNT="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$PLIST" 2>/dev/null | grep -c '^    ' || true)"
for ((index = 0; index < ARG_COUNT; index++)); do
  arg="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:$index" "$PLIST" 2>/dev/null || true)"
  if [ "$arg" = "--host" ]; then
    HOST_INDEX="$index"
  elif [ "$arg" = "--port" ]; then
    PORT_INDEX="$index"
  fi
done

if [ -z "$HOST_INDEX" ] || [ -z "$PORT_INDEX" ]; then
  echo "LaunchAgent ProgramArguments did not include --host and --port."
  echo "Install the LaunchAgent again with ./scripts/install-launch-agent.sh."
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :ProgramArguments:$((HOST_INDEX + 1)) $TAILSCALE_IP" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:$((PORT_INDEX + 1)) $PORT" "$PLIST"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  sleep 1
fi

if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
launchctl kickstart -k "gui/$(id -u)/$LABEL"

sleep 2
if ! nc -z -w 2 "$TAILSCALE_IP" "$PORT" >/dev/null 2>&1; then
  echo "Bridge did not accept TCP connections on $TAILSCALE_IP:$PORT."
  echo "Recent stderr log:"
  tail -n 40 /tmp/maludex-bridge.launchd.err.log 2>/dev/null || true
  exit 1
fi

node --input-type=module - "$TAILSCALE_IP" "$PORT" "$TOKEN_FILE" "$QR_FILE" "$BRIDGE_NAME" <<'NODE'
import { chmodSync, readFileSync } from "node:fs";
import QRCode from "qrcode";

const [host, port, tokenFile, qrFile, name] = process.argv.slice(2);
const token = readFileSync(tokenFile, "utf8").trim();
const query = new URLSearchParams({ host, port, token, tls: "0", name });
await QRCode.toFile(qrFile, `maludex://pair?${query.toString()}`, {
  type: "png",
  margin: 2,
  scale: 8
});
chmodSync(qrFile, 0o600);
NODE

cat <<EOF
Tailscale bridge is ready.

Mac Tailscale IP: $TAILSCALE_IP
Bridge URL: ws://$TAILSCALE_IP:$PORT
Bridge name: $BRIDGE_NAME
Pairing QR: $QR_FILE

Do not share the QR image; it contains the bearer capability token.
EOF
