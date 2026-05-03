#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEVICE_NAME="${MALUDEX_DEMO_DEVICE:-iPhone 17 Pro}"
SCHEME="${MALUDEX_DEMO_SCHEME:-CodexRemoteBridge}"
BUNDLE_ID="${MALUDEX_DEMO_BUNDLE_ID:-com.local.CodexRemoteBridge}"
DERIVED_DATA="${MALUDEX_DEMO_DERIVED_DATA:-/tmp/maludex-demo-derived}"
OUT_DIR="${MALUDEX_DEMO_OUT_DIR:-$ROOT_DIR/media}"
RAW_VIDEO="${MALUDEX_DEMO_RAW:-/tmp/maludex-simulator-demo.mov}"
OUT_VIDEO="${MALUDEX_DEMO_OUT:-$OUT_DIR/maludex-simulator-demo.mp4}"
DURATION="${MALUDEX_DEMO_DURATION:-60}"

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to compress the simulator recording."
  exit 1
fi

DEVICE_ID="$(xcrun simctl list devices available \
  | grep -F "$DEVICE_NAME (" \
  | head -n 1 \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"

if [ -z "$DEVICE_ID" ]; then
  echo "Could not find an available Simulator named: $DEVICE_NAME"
  echo "Set MALUDEX_DEMO_DEVICE to one of:"
  xcrun simctl list devices available
  exit 1
fi

xcodebuild \
  -project ios/CodexRemoteBridge/CodexRemoteBridge.xcodeproj \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  build >/tmp/maludex-demo-xcodebuild.log

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CodexRemoteBridge.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Built app not found at: $APP_PATH"
  echo "See /tmp/maludex-demo-xcodebuild.log"
  exit 1
fi

xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
open -a Simulator --args -CurrentDeviceUDID "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null
xcrun simctl ui "$DEVICE_ID" appearance light >/dev/null || true
xcrun simctl status_bar "$DEVICE_ID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null || true
xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE_ID" "$APP_PATH"
xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true

rm -f "$RAW_VIDEO" "$OUT_VIDEO"
xcrun simctl io "$DEVICE_ID" recordVideo --codec=h264 --force "$RAW_VIDEO" >/tmp/maludex-demo-record.out 2>/tmp/maludex-demo-record.err &
RECORDER_PID=$!

for _ in $(seq 1 30); do
  if grep -q "Recording started" /tmp/maludex-demo-record.err 2>/dev/null; then
    break
  fi
  sleep 0.2
done

xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" --demo-video >/tmp/maludex-demo-launch.log
sleep "$DURATION"
kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
wait "$RECORDER_PID" >/dev/null 2>&1 || true

ffmpeg -y \
  -i "$RAW_VIDEO" \
  -t "$DURATION" \
  -vf "scale=-2:1920,fps=30" \
  -c:v libx264 \
  -preset slow \
  -crf 24 \
  -pix_fmt yuv420p \
  -movflags +faststart \
  "$OUT_VIDEO" >/tmp/maludex-demo-ffmpeg.log 2>&1

echo "$OUT_VIDEO"
