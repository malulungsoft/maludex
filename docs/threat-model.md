# maludex Threat Model

## Assets

- Codex account/session already present on the Mac.
- Local workspace files reachable by Codex.
- Prompt bodies and streamed Codex output.
- Mobile attachment contents copied into selected workspaces.
- Project and recent-thread path metadata.
- Desktop thread titles, previews, and historical transcript excerpts.
- Approval decisions for commands, file changes, and permission requests.
- The QR capability token.
- Saved bridge metadata and per-bridge Keychain tokens on iPhone.

## Trust Boundaries

- maludex iPhone app to Mac bridge over localhost, LAN, or Tailscale.
- Mac bridge to Codex app-server over local child-process stdio.
- Codex app-server to the Mac filesystem and shell according to the active sandbox and approval policy.

There is no cloud relay in this MVP.

## Main Threats And Mitigations

| Threat | Mitigation |
| --- | --- |
| Unauthenticated device drives Codex | Every WebSocket upgrade requires the bearer capability token. |
| Codex app-server exposed directly | Bridge launches Codex only with `--listen stdio://`. |
| Bridge accidentally listens on every interface | Bridge refuses `0.0.0.0` and `::`; use loopback or one Tailscale IP. The Tailscale helper updates the LaunchAgent to one detected `100.x.y.z` address only. |
| Public internet scans reach the bridge | Do not router-port-forward the bridge. Preferred external access is Tailscale with the iPhone and Mac in the same tailnet. If using Nginx, keep the bridge on loopback, terminate TLS at Nginx, preserve bearer auth, and add IP allowlisting, mTLS, or another access layer. |
| Token checked into the repo | Tokens are loaded from a `0600` file; repo ignores local token-like files and docs warn against committing pairing material. |
| Token file readable by other users | Bridge refuses token files whose permissions are not exactly `0600`. |
| Token visible in bridge logs | The QR URI is rendered as a QR code; raw token text is not printed by the CLI logger. |
| Prompt leakage through logs | Bridge logs metadata and prompt byte length only. |
| Desktop handoff inbox leaks prompt bodies | The handoff inbox is separate from bridge logs, stored outside the repo at `~/.codex-iphone-remote-bridge/mobile-handoff.jsonl`, forced to `0600`, and pruned to the most recent 200 entries by default. Users can lower retention with `BRIDGE_MOBILE_HANDOFF_MAX_ENTRIES` or `--mobile-handoff-max-entries`; docs warn not to commit or share it. |
| Remote command execution without review | Threads and turns default to `on-request`; approvals are forwarded to the phone. |
| Excessive filesystem access | Thread default sandbox is `read-only`; workspace-write must be requested explicitly. Mobile clients cannot request `danger-full-access`. |
| Accidental no-approval mode | The bridge rejects mobile attempts to use `approvalPolicy: "never"` and falls back to `on-request`. |
| Subagent changes outside the intended project | Mobile subagents are forked from the active thread and inherit the same safe mobile-selected sandbox and approval policy. |
| Project picker leaks too much path metadata | Project listing is limited to configured roots and recent Codex thread working directories, and requires the bearer token. |
| Chat list leaks private conversation metadata | Chat listing and history loading require the bearer token and are never exposed through unauthenticated WebSocket connections. |
| Diagnostics leak secrets | `bridge.status` returns operational metadata only. It does not include bearer tokens, prompt bodies, command bodies, transcript text, or attachment contents. |
| Paired iPhone leaks persisted content | iOS stores the capability token in Keychain and stores session metadata plus recent transcript locally; the pairing screen has a `Forget` control to clear this device state. |
| One paired PC token grants access to another PC | Each saved bridge has a separate Keychain token keyed by bridge endpoint. Switching bridges uses that bridge's token only, and local transcript snapshots are restored from the active bridge ID. |
| Oversized desktop history crashes or disconnects mobile client | `chat.open` strips raw `thread.turns`, bounds transcript entries/bytes, and reports truncation metadata to the iOS client. |
| Mobile prompt persistence duplicates or leaks content | The bridge first checks recent thread turns before using `thread/inject_items`; it logs only metadata, but the user-authored prompt may be persisted into the selected Codex thread. |
| Attachment previews leak local content to the paired phone | Only authenticated clients can request chat history; image previews are byte-limited, while documents are represented as metadata cards. Treat a paired iPhone as trusted. |
| Attachments write unexpected locations | Attachments are written only under the selected workspace's `.codex-mobile-attachments/` directory with safe filenames and `0600` permissions. |
| Attachment payload exhausts memory or disk | Bridge limits attachments to 5 per turn and 15 MB each. |
| Approval request arrives while phone is offline | Bridge buffers approval events with event IDs for the next authenticated reconnect, then denies them after the approval timeout if no trusted client responds. |
| Stolen QR token reused | Token is high-entropy and file-protected. `npm run rotate-token` replaces it with a new `0600` token, and the running bridge disconnects existing mobile clients after detecting the file change. |
| Slow client consumes unbounded memory | Bridge queues outbound frames up to a cap, then closes the slow client. |

## Residual Risks

- A compromised iPhone can send prompts and approve requests while connected.
- A compromised Mac user account can read bridge process memory and the Codex session.
- QR shoulder-surfing can reveal the token until the token file is rotated.
- Plain `ws://` has no transport encryption. Use Tailscale or localhost; if you expose a domain, terminate TLS with a reverse proxy such as Nginx and add stricter network controls.
- This MVP has no multi-device identity, token revocation UI, or per-device audit trail.
- The iOS app persists bridge capability tokens in Keychain. Anyone who can unlock the paired iPhone may access recent transcript content saved by the app and switch among saved PCs.
- Approval params can include sensitive command paths or filenames because the phone needs them for review.
- Project lists and attachment filenames can reveal local metadata to anyone holding the pairing token.
- Chat titles, previews, and restored transcript content can be sensitive; a paired iPhone should be treated as trusted while connected.
- The desktop handoff inbox can contain iPhone prompt bodies. It is private local state, not public diagnostics; deleting it removes that recovery trail.
- Saved iOS transcript content remains on the device until the user taps `Forget` or deletes the app.

## Security Invariants

- Do not add `codex app-server --listen ws://0.0.0.0` to this project.
- Do not add a no-token WebSocket mode.
- Do not router-port-forward the bridge or bind it to a public address. If Nginx is used, the bridge should remain loopback-only and the public endpoint needs TLS, IP allowlisting or mTLS, token rotation UX, and operational monitoring.
- Do not add `danger-full-access` as a default.
- Do not expose `approvalPolicy: "never"` or full-access controls in the mobile protocol without a new security review.
- Do not log prompt bodies by default.
- Do not commit generated runtime tokens, QR screenshots, or local pairing files.

## Recommended Operating Mode

1. Start on loopback for simulator testing.
2. Use `scripts/configure-tailscale-bridge.sh` to bind the bridge to a private Tailscale IP for a physical iPhone, including off-Wi-Fi use.
3. For Nginx-based access, follow `docs/nginx-reverse-proxy.md` and keep the bridge bound to `127.0.0.1`.
4. Restart the bridge after pairing demos or whenever the QR code may have been exposed.
5. Keep approvals on request.
6. Stop the bridge when not actively using the remote client.
7. Rotate the token with `npm run rotate-token -- --host <host-for-iphone> --port 8765`.
