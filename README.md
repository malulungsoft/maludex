# maludex

maludex is a local-first iPhone companion by malulung soft for driving Codex on one or more Macs.

The Mac bridge launches `codex app-server` over stdio JSONL and exposes a narrow authenticated WebSocket API for the iPhone app. maludex does **not** expose `codex app-server --listen ws://0.0.0.0`, and v1 has no cloud relay.

## Status

This repository is an MVP. It is useful for private local/Tailscale workflows, but it should not be treated as hardened remote administration software.

## Features

- SwiftUI iPhone client with QR pairing, camera scanner, connection status, project picker, prompt composer, streaming transcript, approval cards, attachment picker, voice input, and local transcript persistence.
- Multiple saved Mac bridges, each with its own Keychain token and per-bridge session state.
- Node.js + TypeScript Mac bridge that translates between mobile WebSocket messages and Codex JSON-RPC over stdio JSONL.
- Project listing and project creation under configured roots.
- Desktop chat list and bounded history loading.
- Model, reasoning effort, permission mode, and context-compaction controls.
- Image and file attachments copied into the selected workspace before a turn.
- Subagent start, manual compact, approval response, and active-turn stop.
- Integration tests with a mocked Codex app-server process.

## Security Warnings

- Use maludex only on networks you control: localhost, the iOS simulator, LAN you trust, or a private Tailscale IP.
- Do not router-port-forward the bridge to the public internet.
- The bridge refuses wildcard WebSocket binds such as `0.0.0.0`; bind to `127.0.0.1`, `::1`, or one specific Tailscale IP.
- Every WebSocket upgrade must include the QR capability token as `Authorization: Bearer <token>`.
- The token is loaded from a `0600` file. By default the CLI creates `~/.codex-iphone-remote-bridge/token`.
- Do not commit token files, QR screenshots, pairing payload text, logs with prompt bodies, local attachments, or Xcode user state.
- The bridge defaults to `approvalPolicy: "on-request"` and `sandbox: "read-only"`.
- The mobile app can request only `read-only` or `workspace-write`; it does not expose `danger-full-access` or `approvalPolicy: "never"`.
- Prompt bodies are sent to Codex but are not logged by the bridge by default.
- Mobile attachments are copied into the selected workspace under `.codex-mobile-attachments/` with `0600` file permissions. Treat those files as local project data.
- A paired and unlocked iPhone should be treated as a trusted device. It can view recent transcript content and respond to approval requests.
- Plain `ws://` has no transport encryption by itself. Use localhost or Tailscale. Add TLS and stronger operational controls before considering any public endpoint.

## Requirements

- macOS with Codex installed and logged in.
- Node.js 20 or newer.
- npm.
- Xcode with iOS support for building the SwiftUI client.
- Tailscale on both the Mac and iPhone if you want to connect from outside your local Wi-Fi.

## Install The Bridge

```bash
git clone https://github.com/malulungsoft/maludex.git
cd maludex
./scripts/setup-local.sh
```

Run the bridge manually for local simulator testing:

```bash
npm run dev -- --host 127.0.0.1 --port 8765
```

Run it manually for a physical iPhone over Tailscale:

```bash
npm run dev -- --host <your-mac-tailscale-ip> --port 8765
```

The CLI prints a QR code unless `--no-qr` is passed. Scan that QR from the iPhone app. The QR contains the bearer capability token, so treat it like a password.

## Install As A macOS LaunchAgent

For a bridge that starts in the background on login:

```bash
./scripts/install-launch-agent.sh
```

That installs a LaunchAgent named `com.maludex.bridge`, creates the default token file if needed, verifies the TypeScript build, and starts the bridge on `127.0.0.1:8765`.

For a physical iPhone or off-Wi-Fi usage through Tailscale:

```bash
./scripts/configure-tailscale-bridge.sh
```

That script detects the Mac's Tailscale IPv4 address, updates the LaunchAgent to bind only to that one `100.x.y.z` address, restarts the bridge, and writes a pairing QR image to `/tmp/maludex-pairing.png`.

## iPhone App

Open `ios/CodexRemoteBridge/CodexRemoteBridge.xcodeproj` in Xcode.

Before installing on your own iPhone:

1. Select the `CodexRemoteBridge` project in Xcode.
2. Open **Signing & Capabilities**.
3. Choose your Apple development team.
4. Change the bundle identifier if Xcode asks for a unique value.
5. Build and run on your device.

The installed display name is `maludex`.

## Pairing

The bridge emits a pairing URI in this shape:

```text
maludex://pair?host=100.x.y.z&port=8765&token=...&tls=0&name=Studio%20Mac
```

Pairing options in the app:

- Scan the QR code.
- Paste the pairing payload.
- Scan each additional Mac's QR to add it to the bridge switcher.

The iOS app stores each bridge token in Keychain. Non-token session state, such as the selected project, active thread, event id, and recent transcript, is stored locally on the device per bridge.

## Multiple Macs

Install and run the bridge on every Mac you want to control. Each Mac must have its own token file and QR pairing payload.

On the iPhone:

1. Pair the first Mac.
2. Pair the second Mac by scanning its QR.
3. Use the bridge switcher in the project screen to move between saved Macs.

Switching bridges closes the current WebSocket, restores that Mac's saved local session snapshot, and reconnects with that Mac's own bearer token.

## Project Layout

- `bridge/src`: Node.js TypeScript bridge.
- `bridge/test`: integration test with a mock Codex app-server JSON-RPC process.
- `ios/CodexRemoteBridge`: SwiftUI iOS app.
- `docs/architecture.md`: component and protocol design.
- `docs/threat-model.md`: MVP threat model and residual risks.
- `scripts/setup-local.sh`: local dependency and build setup.
- `scripts/install-launch-agent.sh`: macOS LaunchAgent installer.
- `scripts/configure-tailscale-bridge.sh`: private external access setup through Tailscale.

## Development

```bash
npm install
npm run build
npm test
```

Swift model tests can be compiled and run without opening Xcode:

```bash
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
  ios/CodexRemoteBridge/Tests/TranscriptStoreTests.swift \
  -o /tmp/maludex-transcript-store-tests
/tmp/maludex-transcript-store-tests
```

## Runtime Data That Must Stay Local

Do not commit:

- `~/.codex-iphone-remote-bridge/token`
- QR images or copied pairing payloads
- `.codex-mobile-attachments/`
- Xcode `xcuserdata/` and `*.xcuserstate`
- logs containing prompt bodies or private paths
- generated app archives that may include signing metadata

## License

maludex is open source under the [Apache License 2.0](LICENSE).
