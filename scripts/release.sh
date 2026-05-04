#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/release.sh vX.Y.Z [--check-only] [--push]

Checks version consistency, runs local verification, optionally creates and
pushes the release tag.

Set MALUDEX_RELEASE_ALLOW_DIRTY_SIGNING=1 to ignore the local Xcode signing
project file while checking the worktree.
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

tag="$1"
shift
check_only=0
push_release=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      check_only=1
      ;;
    --push)
      push_release=1
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

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Tag must look like vX.Y.Z" >&2
  exit 64
fi

version="${tag#v}"
cd "$(dirname "$0")/.."

dirty_files="$(git status --porcelain | awk '{print $2}')"
if [[ -n "$dirty_files" ]]; then
  if [[ "${MALUDEX_RELEASE_ALLOW_DIRTY_SIGNING:-0}" == "1" ]]; then
    dirty_files="$(printf '%s\n' "$dirty_files" | grep -v '^ios/CodexRemoteBridge/CodexRemoteBridge.xcodeproj/project.pbxproj$' || true)"
  fi
  if [[ -n "$dirty_files" ]]; then
    echo "Worktree has uncommitted files:" >&2
    printf '%s\n' "$dirty_files" >&2
    exit 65
  fi
fi

required_files=(
  package.json
  package-lock.json
  README.md
  CHANGELOG.md
  ios/CodexRemoteBridge/Info.plist
  bridge/src/bridge-server.ts
  bridge/test/bridge.integration.test.ts
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/ClientModels.swift
)

for file in "${required_files[@]}"; do
  if ! grep -q "$version" "$file"; then
    echo "$file does not contain $version" >&2
    exit 66
  fi
done

node scripts/extract-release-notes.mjs "$version" CHANGELOG.md >/tmp/maludex-release-notes.md
npm ci
npm run build
npm test
swift test --package-path macos/MaludexControlCenter
swift build --package-path macos/MaludexControlCenter

swiftc -parse-as-library \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/JSONValue.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/TranscriptStore.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/ClientModels.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/Pairing.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/DeviceStateStore.swift \
  ios/CodexRemoteBridge/Tests/ClientModelsTests.swift \
  -o /tmp/maludex-client-models-tests
/tmp/maludex-client-models-tests

swiftc -parse-as-library \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/JSONValue.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/ClientModels.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/TranscriptStore.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/Pairing.swift \
  ios/CodexRemoteBridge/Sources/CodexRemoteBridge/DeviceStateStore.swift \
  ios/CodexRemoteBridge/Tests/TranscriptStoreTests.swift \
  -o /tmp/maludex-transcript-store-tests
/tmp/maludex-transcript-store-tests

xcodebuild -project ios/CodexRemoteBridge/CodexRemoteBridge.xcodeproj -scheme CodexRemoteBridge -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

if [[ "$check_only" == "1" ]]; then
  echo "Release check passed for $tag"
  exit 0
fi

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists" >&2
  exit 67
fi

git tag -a "$tag" -F /tmp/maludex-release-notes.md

if [[ "$push_release" == "1" ]]; then
  current_branch="$(git branch --show-current)"
  git push origin "HEAD:$current_branch"
  git push origin "$tag"
fi

echo "Created $tag"
