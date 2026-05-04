#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="${MALUDEX_DEMO_OUT_DIR:-$ROOT_DIR/media}"
OUT_VIDEO="${MALUDEX_DEMO_OUT:-$OUT_DIR/maludex-simulator-demo.mp4}"
OUT_GIF="${MALUDEX_DEMO_GIF:-$OUT_DIR/maludex-simulator-demo.gif}"
SCREENSHOT_DIR="${MALUDEX_DEMO_SCREENSHOT_DIR:-$OUT_DIR/screenshots}"
FRAME_DURATION="${MALUDEX_DEMO_FRAME_DURATION:-1.8}"
GIF_WIDTH="${MALUDEX_DEMO_GIF_WIDTH:-360}"
MP4_HEIGHT="${MALUDEX_DEMO_MP4_HEIGHT:-1920}"
MP4_CRF="${MALUDEX_DEMO_MP4_CRF:-24}"

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to build the README demo media."
  exit 1
fi

screenshots=(
  pairing
  connected-home
  session-controls
  streaming-turn
  approval-card
  bridge-switcher
)

for screenshot in "${screenshots[@]}"; do
  if [ ! -f "$SCREENSHOT_DIR/$screenshot.png" ]; then
    echo "Missing $SCREENSHOT_DIR/$screenshot.png"
    echo "Capture the real app in iOS Simulator first, then rerun this script."
    exit 1
  fi
done

FRAMES_FILE="$(mktemp -t maludex-demo-frames.XXXXXX)"
trap 'rm -f "$FRAMES_FILE"' EXIT

for screenshot in "${screenshots[@]}"; do
  printf "file '%s/%s.png'\n" "$SCREENSHOT_DIR" "$screenshot" >>"$FRAMES_FILE"
  printf "duration %s\n" "$FRAME_DURATION" >>"$FRAMES_FILE"
done

last_index=$((${#screenshots[@]} - 1))
printf "file '%s/%s.png'\n" "$SCREENSHOT_DIR" "${screenshots[$last_index]}" >>"$FRAMES_FILE"

ffmpeg -y \
  -f concat \
  -safe 0 \
  -i "$FRAMES_FILE" \
  -vf "fps=30,scale=-2:${MP4_HEIGHT}:flags=lanczos,format=yuv420p" \
  -c:v libx264 \
  -preset slow \
  -crf "$MP4_CRF" \
  -movflags +faststart \
  "$OUT_VIDEO" >/tmp/maludex-demo-mp4.log 2>&1

ffmpeg -y \
  -f concat \
  -safe 0 \
  -i "$FRAMES_FILE" \
  -filter_complex "[0:v]fps=8,scale=${GIF_WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
  -loop 0 \
  "$OUT_GIF" >/tmp/maludex-demo-gif.log 2>&1

echo "$OUT_VIDEO"
echo "$OUT_GIF"
