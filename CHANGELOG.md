# Changelog

## 0.6.6 - 2026-05-05

- Add a Mobile Handoff panel to the macOS Control Center so recent iPhone-authored prompts can be reviewed without terminal commands.
- Decode handoff inbox JSON in the Control Center core target, including bounded prompt previews and attachment metadata.
- Keep the handoff panel private/local with an explicit prompt-body warning.

## 0.6.5 - 2026-05-05

- Add English/Korean language switching to the iPhone app, with English as the default.
- Persist the selected iPhone app language in device state so app relaunches do not reset it.
- Add English/Korean language switching to the macOS Control Center and preserve it with AppStorage.

## 0.6.4 - 2026-05-05

- Keep Codex approval requests pending when the iPhone is temporarily disconnected instead of immediately declining them.
- Replay pending approval cards to the next authenticated iPhone reconnect and keep the accepted response wired to Codex.
- Add regression coverage for reconnect-safe approvals during mobile background/disconnect windows.

## 0.6.3 - 2026-05-05

- Add a private desktop handoff inbox for iPhone-authored prompts so desktop Codex can explicitly recover mobile instructions that were not live-shared into the open desktop conversation.
- Add `npm run handoff` to print recent mobile handoff entries from the local `0600` inbox.
- Document that the handoff inbox can contain prompt bodies and must never be committed or shared.

## 0.6.2 - 2026-05-05

- Fix the macOS Control Center app so it can find Homebrew-installed `node` and `npm` when launched from Xcode or Finder.
- Notify the iPhone user when a Codex approval request arrives while maludex is inactive or backgrounded.
- Keep foreground approval requests in the in-app approval card without also creating a local notification.

## 0.6.1 - 2026-05-05

- Compact the iPhone chat header and prompt composer so more transcript content is visible on large phones.
- Hide the project header and empty composer while scrolling through chat history, and restore them when scrolling back up or focusing input.
- Keep approval cards, attachments, and drafted prompts visible so active work is not hidden during scrolling.

## 0.6.0 - 2026-05-05

- Add a standalone SwiftUI macOS Control Center app for bridge health, endpoint, version, LaunchAgent, and token status.
- Add a shared TypeScript doctor engine and `npm run doctor -- --json` for redacted machine-readable bridge diagnostics.
- Add Control Center actions for LaunchAgent repair, start, stop, restart, token rotation, and pairing QR generation.
- Detect stale LaunchAgent repo paths and old bridge entrypoints as repairable errors.
- Add macOS Control Center SwiftPM tests/builds to local release checks and GitHub CI.

## 0.5.0 - 2026-05-05

- Persist queued iPhone prompts to a local `0600` queue file and restore them after bridge restarts.
- Resume restored queued turns after an authenticated mobile reconnect, while keeping bridge logs metadata-only.
- Reset the iPhone replay cursor safely when a restarted bridge reports a lower event id.
- Add local iOS notifications for approval requests, completed turns, and queued prompt failures.
- Document that the queue state can contain prompt bodies and attachment references and must stay private.

## 0.4.4 - 2026-05-05

- Fix the iPhone chat screen layout on large phones and larger text settings by constraining the project header, transcript bubbles, and prompt composer controls to the viewport.
- Switch repository-local Git author metadata to `malulungbot <malulungbot@gmail.com>` for future GitHub updates.

## 0.4.3 - 2026-05-04

- Add a mobile prompt queue: prompts sent while a Codex turn is active are queued and automatically run in order.
- Add queue reordering and cancellation controls from the iPhone app.
- Add turn steering so the iPhone app can send additional guidance to the active Codex turn.
- Collapse long transcript bubbles by default to make mobile chat history easier to scroll.

## 0.4.2 - 2026-05-04

- Persist iPhone-authored prompts into Codex desktop thread history as soon as a turn starts, so interrupted or long-running turns remain recoverable without logging raw prompt bodies.
- Keep bridge logs metadata-only while preserving mobile prompt recovery through Codex thread history and the iPhone's local transcript storage.

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
