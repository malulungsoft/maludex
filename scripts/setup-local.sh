#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 20 or newer is required."
  exit 1
fi

NODE_MAJOR="$(node -p "Number(process.versions.node.split('.')[0])")"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "Node.js 20 or newer is required. Found $(node -v)."
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI is required. Install and log in before running the bridge."
  exit 1
fi

npm install
npm run build

cat <<'EOF'

Local setup complete.

Simulator/local test:
  npm run dev -- --host 127.0.0.1 --port 8765

Physical iPhone over Tailscale:
  npm run dev -- --host <your-mac-tailscale-ip> --port 8765

Background LaunchAgent:
  ./scripts/install-launch-agent.sh
  ./scripts/configure-tailscale-bridge.sh

The bridge reads its QR capability token from ~/.codex-iphone-remote-bridge/token by default.
The token file must remain chmod 600; replace it when you want to rotate pairing.
EOF
