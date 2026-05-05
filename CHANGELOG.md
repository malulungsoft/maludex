# Changelog

## 0.9.7 - 2026-05-06

- Keep fresh or reset mobile clients connected by skipping bulk event replay when no reconnect cursor is provided.
- Emit a refresh gap instead of replaying an oversized buffered event burst, preventing `1013 client too slow` disconnects on stale iPhone sessions.
- Make `bridge.status` respond immediately instead of waiting for Desktop workspace reconciliation.

## 0.9.6 - 2026-05-05

- Match Codex Desktop's own workspace activation flow for mobile-created or mobile-opened projects.
- Promote the active mobile project to the front of Desktop workspace options and project order, while background reconciliation no longer rewrites the active project.
- Notify the running macOS Codex app through `open -g -a Codex <project>` so the in-memory Desktop UI can refresh without waiting for a full app restart.

## 0.9.5 - 2026-05-05

- Reconcile Codex Desktop workspace roots from recent Codex threads on bridge startup, mobile reconnect, periodic checks, and bridge status refresh.
- Repair cases where Codex Desktop rewrites `~/.codex/.codex-global-state.json` and drops a mobile-created project such as `webnovel`.
- Keep desktop thread index labels based on workspace names during reconciliation instead of prompt bodies.

## 0.9.4 - 2026-05-05

- Add a Codex-style slash command palette to the iPhone prompt composer and expanded composer.
- Suggest localized skill, plugin, mode, model, queue, and subagent commands when the active line starts with `/`.
- Insert the selected command as an editable prompt instruction without changing bridge security defaults or logging prompt bodies.

## 0.9.3 - 2026-05-05

- Register mobile-started threads in Codex Desktop's local `session_index.jsonl` so iPhone-created chat rooms can appear after restarting the desktop app.
- Back the desktop thread index sync with regression tests and keep thread index names short instead of writing prompt bodies into the index.

## 0.9.2 - 2026-05-05

- Register mobile-created and mobile-selected project paths in Codex Desktop workspace state so iPhone-created projects and their Codex threads are visible in the desktop app.
- Add `BRIDGE_SYNC_CODEX_DESKTOP=0` / `--no-desktop-sync` for users who do not want maludex to touch Codex Desktop workspace-root state.

## 0.9.1 - 2026-05-05

- Rebuild the README demo GIF as a continuous animation from real Xcode iOS Simulator video instead of a static cut reel.
- Skip first-run onboarding while the app is launched in README demo mode so the capture shows the actual chat UI.

## 0.9.0 - 2026-05-05

- Add replay-gap bridge notifications with oldest/latest event IDs so reconnecting iPhone clients can catch up safely.
- Emit desktop thread-activity hints for completed turns and persisted items, prompting bounded mobile transcript refreshes when needed.
- Show iPhone request delivery and desktop-history persistence status in the mobile transcript without logging prompt bodies by default.
- Keep approval cards visible until bridge confirmation and add explicit approval-resolution transcript messages.
- Add iPhone setup checklist guidance for bridge connection, QR pairing, project selection, and approval notifications.
- Add a macOS Control Center action log for update, repair, start/stop/restart, pairing QR, and token rotation operations.

## 0.8.0 - 2026-05-05

- Add Desktop Sync 2.0 status states for up-to-date, delayed, catching-up, and recovered transcript updates.
- Detect reconnect event gaps on iPhone and trigger an immediate bounded desktop transcript catch-up refresh.
- Add a Control Center Update action that pulls the repo, reinstalls dependencies, rebuilds, and restarts the bridge when versions drift.
- Add a first-run iPhone onboarding flow for private routes, QR token safety, and desktop sync expectations.
- Improve iPhone chat UX with notification-permission recovery, one-tap fenced-code copying, and tap-to-expand image attachments.

## 0.7.5 - 2026-05-05

- Add an iPhone transcript sync status bar with last-synced age and a manual refresh action.
- Improve active-chat catch-up by allowing stale active turns to recover with a bounded desktop transcript refresh.
- Rework README installation guidance around the macOS Control Center, leaving terminal commands as a fallback path.

## 0.7.4 - 2026-05-05

- Replace the README hero media with a fast animated cut reel GIF built from real iOS Simulator capture frames.
- Remove the redundant six-image screenshot grid from the GitHub landing page.
- Stop publishing standalone README screenshot assets from the demo generation script.

## 0.7.3 - 2026-05-05

- Replace the README demo media pipeline with a real Xcode iOS Simulator recording of the installed SwiftUI app.
- Add an iPhone demo scenario that exercises the actual maludex chat UI, prompt queue, attachment preview, streaming state, and approval card.
- Refresh README screenshots from captured Simulator video frames instead of hand-rendered mock images.
- Improve iPhone transcript catch-up so foregrounding or heartbeat checks refresh completed desktop chat updates without reopening the thread.

## 0.7.2 - 2026-05-05

- Fix macOS Control Center repair so GUI-launched doctor commands preserve Homebrew/Node tool paths for LaunchAgent reinstall.
- Show child process stderr/stdout when doctor repair fails instead of only reporting a generic command failure.

## 0.7.1 - 2026-05-05

- Add iPhone transcript search with Korean/English copy, attachment filename matches, and tap-to-scroll results.
- Expand and briefly highlight long transcript bubbles when opened from iPhone search results.

## 0.7.0 - 2026-05-05

- Add searchable iPhone project and model picker sheets, including model capability badges.
- Add iPhone project favorites so frequently used workspaces can be pinned above the full project list.
- Reuse the searchable model picker from Session settings so long model lists stay manageable.
- Add quick prompt chips and a full-screen composer for longer iPhone prompts, with per-bridge draft persistence.
- Add editable saved quick prompts on iPhone, including local persistence, edit, delete, and reorder controls.
- Add saved bridge renaming on iPhone so multiple paired Macs can be labeled clearly.
- Add search to the saved bridge switcher for multi-PC setups.
- Add queue count diagnostics, collapsed queue UI, composer status chips, attachment thumbnails, and collapsed long transcript bubbles.
- Improve the macOS Control Center Mobile Handoff panel with full prompt expand/copy actions and QR image copy/reveal controls.
- Add a recommended next-step card to the macOS Control Center and make bridge action buttons adaptive so the layout behaves better at smaller window sizes.

## 0.6.19 - 2026-05-05

- Add a shared pairing URI helper so bridge, doctor, and token rotation QR flows encode pairing payloads consistently.
- Add `--tls` / `BRIDGE_TLS=1` support to the live bridge QR and doctor pairing QR generation for Nginx/TLS endpoints.
- Add regression coverage for `tls=0` local pairing and `tls=1` remote TLS pairing payloads.

## 0.6.18 - 2026-05-05

- Include the effective mobile handoff retention count in token-free `bridge.status` diagnostics.
- Show mobile handoff retention in the iPhone Diagnostics screen and copied diagnostics report.
- Share the handoff retention bounding helper between the bridge server and handoff store.

## 0.6.17 - 2026-05-05

- Add `BRIDGE_MOBILE_HANDOFF_MAX_ENTRIES` and `--mobile-handoff-max-entries` to tune how many iPhone-authored handoff prompts are retained.
- Pass the retention setting through the LaunchAgent installer.
- Add bridge integration coverage for configured mobile handoff retention.

## 0.6.16 - 2026-05-05

- Teach `maludex doctor` to flag pairing token files with less than 32 bytes of token material.
- Mark short-token repairs as repairable so the Control Center can guide users to rotate the token.
- Add doctor regression coverage for short token files before bridge status checks run.

## 0.6.15 - 2026-05-05

- Add an iPhone Diagnostics recovery action that opens the app's Settings page when local notifications are denied.
- Explain that notification permission is required for background approval alerts.
- Add English/Korean copy coverage for the notification recovery path.

## 0.6.14 - 2026-05-05

- Teach `maludex doctor` to flag LaunchAgents configured with unsafe wildcard bridge hosts such as `0.0.0.0` or `::`.
- Mark wildcard host repairs as repairable so the Control Center can guide users back to localhost or a specific Tailscale IP.
- Add doctor regression coverage for unsafe external bind detection before the bridge starts.

## 0.6.13 - 2026-05-05

- Prune the private desktop mobile-handoff inbox to the most recent 200 entries by default.
- Keep handoff retention files at `0600` after pruning so prompt bodies remain private local state.
- Add regression coverage for handoff retention ordering and permissions.

## 0.6.12 - 2026-05-05

- Show the iOS local notification authorization status in the in-app Diagnostics screen.
- Refresh notification authorization state when the app foreground/background state changes.
- Add English/Korean labels for notification diagnostics so approval-alert issues are easier to debug on-device.

## 0.6.11 - 2026-05-05

- Re-schedule local iOS approval reminders when maludex is sent to the background while approval cards are still pending.
- Skip duplicate reminder scheduling for approvals that already have a response waiting for bridge confirmation.
- Document the local-only background notification behavior and its APNs-free limitations.

## 0.6.10 - 2026-05-05

- Show an explicit iPhone approval "waiting for bridge" state after Approve or Deny is tapped.
- Disable approval action buttons while the bridge is confirming the response, preventing accidental duplicate approval sends.
- Clear the waiting state consistently on success, failure, disconnect, turn completion, or bridge-side approval resolution.

## 0.6.9 - 2026-05-05

- Keep iPhone approval cards visible until the bridge confirms the approval response, instead of hiding them immediately on tap, and suppress duplicate approval taps while confirmation is pending.
- Emit replay-safe `approval.responded` / `approval.resolved` bridge events so mobile clients can reconcile approval state.
- Add integration coverage for approval response confirmation after reconnect-safe approval replay.

## 0.6.8 - 2026-05-05

- Add `scripts/build-control-center-app.sh` to package the SwiftPM macOS Control Center executable as a local `.app` bundle.
- Add `npm run build:control-center` and `npm run install:control-center` for easier Control Center builds and installs.
- Verify Control Center app bundle packaging during the local release check.
- Document opening and installing the generated `maludex Control Center.app` without going through Xcode.

## 0.6.7 - 2026-05-05

- Improve macOS Control Center tool resolution for Node managers such as Volta, asdf, mise, and nvm when launched outside Terminal.
- Add a managed shell fallback that can bootstrap nvm/asdf/mise before running `node` or `npm`.
- Document Control Center Node path recovery through automatic discovery and `MALUDEX_NODE_PATH` / `MALUDEX_NPM_PATH` overrides.

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
