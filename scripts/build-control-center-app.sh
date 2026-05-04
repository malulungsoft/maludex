#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/build-control-center-app.sh [--install] [--install-dir DIR]

Builds the maludex Control Center macOS app bundle from the SwiftPM package.

Options:
  --install          Copy the built app to /Applications when writable, otherwise ~/Applications.
  --install-dir DIR  Copy the built app to DIR after building.
  -h, --help         Show this help.
USAGE
}

install_app=0
install_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      install_app=1
      ;;
    --install-dir)
      install_app=1
      shift
      if [[ $# -eq 0 ]]; then
        echo "--install-dir requires a directory" >&2
        exit 64
      fi
      install_dir="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_path="$repo_root/macos/MaludexControlCenter"
bundle_root="$repo_root/dist/maludex-control-center"
app_name="maludex Control Center.app"
app_path="$bundle_root/$app_name"
executable_name="MaludexControlCenter"
version="$(cd "$repo_root" && node -p "require('./package.json').version")"

swift build \
  --package-path "$package_path" \
  -c release \
  --product "$executable_name"

bin_path="$(swift build --package-path "$package_path" -c release --show-bin-path)"
binary="$bin_path/$executable_name"
if [[ ! -x "$binary" ]]; then
  echo "Built executable not found: $binary" >&2
  exit 66
fi

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary" "$app_path/Contents/MacOS/$executable_name"
chmod 755 "$app_path/Contents/MacOS/$executable_name"

cat >"$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>maludex Control Center</string>
  <key>CFBundleExecutable</key>
  <string>$executable_name</string>
  <key>CFBundleIdentifier</key>
  <string>com.malulungsoft.maludex.ControlCenter</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>maludex Control Center</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $app_path"

if [[ "$install_app" == "1" ]]; then
  if [[ -z "$install_dir" ]]; then
    if [[ -w "/Applications" ]]; then
      install_dir="/Applications"
    else
      install_dir="$HOME/Applications"
    fi
  fi

  mkdir -p "$install_dir"
  installed_path="$install_dir/$app_name"
  rm -rf "$installed_path"
  ditto "$app_path" "$installed_path"
  echo "Installed $installed_path"
fi
