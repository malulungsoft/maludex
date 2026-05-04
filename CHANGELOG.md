# Changelog

## 0.4.1 - 2026-05-04

- Show relative timestamps on transcript bubbles in the iPhone app.
- Add Swift model coverage for Korean relative message time formatting.

## 0.4.0 - 2026-05-04

- Add GitHub Actions CI for Node, TypeScript, Swift model tests, Swift transcript tests, and Xcode simulator builds.
- Add tag-driven GitHub Release automation that extracts notes from `CHANGELOG.md`.
- Add `scripts/release.sh` and `npm run release:check` for repeatable local release verification.
- Extend bridge diagnostics with token-free active turn and pending approval details.
- Show active turn and pending approval diagnostics in the iPhone app.

## 0.2.0 - 2026-05-04

- Add `bridge.status` diagnostics with bridge version, Codex process status, token-file validity, runtime counters, and uptime.
- Add an iOS diagnostics dashboard with refresh, recovery hints, and token-free copyable reports.
- Log diagnostics requests as metadata only.

## 0.1.4 - 2026-05-04

- Add `npm run rotate-token` to replace the bridge pairing token and generate a fresh QR.
- Detect token file changes in the running bridge and disconnect existing mobile clients after rotation.
- Reject old bearer credentials immediately after token rotation.

## 0.1.3 - 2026-05-04

- Add bridge/client protocol compatibility metadata to `bridge.ready`.
- Show clearer iOS messages for unreachable bridge, authentication, inactive stop, and request failures.
- Surface bridge version in the iOS connection event stream.

## 0.1.2 - 2026-05-04

- Document an Nginx TLS reverse-proxy deployment option while keeping the bridge bound to loopback.
- Harden iOS local persistence so restored transcripts are normalized from the active bridge ID before display.
- Keep mobile bridge switching from showing stale transcript snapshots from another pairing.

## 0.1.1 - 2026-05-04

- Reconnect the iOS bridge after sleep, foreground resume, and stale WebSocket failures.
- Add lightweight heartbeat pings so dead sockets are detected without noisy alerts.
- Load chat transcripts newest-first and fetch older history pages only when scrolling upward.
- Add bridge integration coverage for cursor-based chat history loading.

## 0.1.0 - 2026-05-03

- Initial maludex bridge and iOS client MVP.
