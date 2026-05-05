#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="${MALUDEX_DEMO_OUT_DIR:-$ROOT_DIR/media}"
OUT_VIDEO="${MALUDEX_DEMO_OUT:-$OUT_DIR/maludex-simulator-demo.mp4}"
OUT_GIF="${MALUDEX_DEMO_GIF:-$OUT_DIR/maludex-simulator-cuts.gif}"
DERIVED_DATA="${MALUDEX_DEMO_DERIVED_DATA:-/tmp/maludex-demo-derived-data}"
DEVICE_NAME="${MALUDEX_DEMO_DEVICE:-iPhone 17 Pro}"
DEMO_DURATION="${MALUDEX_DEMO_DURATION:-60}"
PRE_RECORD_DELAY="${MALUDEX_DEMO_PRE_RECORD_DELAY:-3}"
GIF_WIDTH="${MALUDEX_DEMO_GIF_WIDTH:-420}"
GIF_CUT_DURATION="${MALUDEX_DEMO_GIF_CUT_DURATION:-1.15}"
GIF_CUT_OFFSETS="${MALUDEX_DEMO_GIF_CUT_OFFSETS:-2 14 32 38 50 56}"
MP4_HEIGHT="${MALUDEX_DEMO_MP4_HEIGHT:-1920}"
MP4_CRF="${MALUDEX_DEMO_MP4_CRF:-24}"
BUNDLE_ID="com.local.CodexRemoteBridge"
RAW_VIDEO="$(mktemp -t maludex-simulator-raw.XXXXXX).mp4"
CUT_FRAME_DIR="$(mktemp -d -t maludex-simulator-cuts.XXXXXX)"
CUTS_FILE="$(mktemp -t maludex-simulator-cuts.XXXXXX)"
RECORDER_PID=""

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to build the README demo media."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
  echo "Xcode command line tools are required to capture the real iOS Simulator demo."
  exit 1
fi

cleanup() {
  if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
    wait "$RECORDER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$RAW_VIDEO" "$CUTS_FILE"
  rm -rf "$CUT_FRAME_DIR"
}
trap cleanup EXIT

device_udid() {
  xcrun simctl list devices available | awk -v name="$DEVICE_NAME" '
    index($0, name " (") {
      if (match($0, /\(([0-9A-Fa-f-]{36})\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  '
}

UDID="$(device_udid)"
if [[ -z "$UDID" ]]; then
  echo "Could not find an available Simulator named '$DEVICE_NAME'."
  echo "Set MALUDEX_DEMO_DEVICE to one of:"
  xcrun simctl list devices available | sed -n 's/^    \([^()]*\) (.*/  - \1/p' | sort -u
  exit 1
fi

echo "Building maludex iOS app for $DEVICE_NAME..."
xcodebuild \
  -derivedDataPath "$DERIVED_DATA" \
  -project ios/CodexRemoteBridge/CodexRemoteBridge.xcodeproj \
  -scheme CodexRemoteBridge \
  -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/maludex-demo-xcodebuild.log

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CodexRemoteBridge.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app was not found at $APP_PATH"
  exit 1
fi

echo "Booting Simulator $DEVICE_NAME ($UDID)..."
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/tmp/maludex-demo-bootstatus.log
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Recording real Simulator UI for ${DEMO_DURATION}s..."
xcrun simctl launch "$UDID" "$BUNDLE_ID" --demo-ui >/tmp/maludex-demo-launch.log
sleep "$PRE_RECORD_DELAY"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$RAW_VIDEO" >/tmp/maludex-demo-record-video.log 2>&1 &
RECORDER_PID="$!"
sleep 2
sleep "$DEMO_DURATION"
kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
wait "$RECORDER_PID" >/dev/null 2>&1 || true
RECORDER_PID=""

ffmpeg -y \
  -i "$RAW_VIDEO" \
  -vf "scale=-2:${MP4_HEIGHT}:flags=lanczos,format=yuv420p" \
  -an \
  -c:v libx264 \
  -preset slow \
  -crf "$MP4_CRF" \
  -movflags +faststart \
  "$OUT_VIDEO" >/tmp/maludex-demo-mp4.log 2>&1

>"$CUTS_FILE"
cut_index=0
last_frame=""
for offset in $GIF_CUT_OFFSETS; do
  frame="$CUT_FRAME_DIR/cut-${cut_index}.png"
  ffmpeg -y \
    -ss "$offset" \
    -i "$OUT_VIDEO" \
    -frames:v 1 \
    "$frame" >/tmp/maludex-demo-cut-frame.log 2>&1
  printf "file '%s'\n" "$frame" >>"$CUTS_FILE"
  printf "duration %s\n" "$GIF_CUT_DURATION" >>"$CUTS_FILE"
  last_frame="$frame"
  cut_index=$((cut_index + 1))
done

if [[ "$cut_index" == "0" ]]; then
  echo "No GIF cut offsets were provided."
  exit 1
fi

printf "file '%s'\n" "$last_frame" >>"$CUTS_FILE"

ffmpeg -y \
  -f concat \
  -safe 0 \
  -i "$CUTS_FILE" \
  -filter_complex "[0:v]fps=8,scale=${GIF_WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
  -loop 0 \
  "$OUT_GIF" >/tmp/maludex-demo-gif.log 2>&1

echo "$OUT_VIDEO"
echo "$OUT_GIF"
