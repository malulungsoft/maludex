# maludex iOS Client

This folder contains the SwiftUI source for the maludex local-first iPhone client.

Open `CodexRemoteBridge.xcodeproj` in Xcode. It already contains a minimal iOS SwiftUI app target named `CodexRemoteBridge` with the files in `Sources/CodexRemoteBridge` attached to the app target.

The installed app display name is `maludex`. The target uses bundle id `com.local.CodexRemoteBridge`, iPhone-only device family, and iOS 17.0 deployment target. No personal development team is committed. In Xcode, set your Apple development team under Signing & Capabilities before running on a physical iPhone, and change the bundle id if Xcode asks for a unique value.

The client stores each paired bridge token in iOS Keychain after scanning or pasting a QR pairing URI. It stores the last selected bridge plus per-bridge project, model, intelligence level, permission mode, compaction setting, active thread, event id, and recent transcript in local device preferences. Use a bridge row's `Forget` action to remove one saved PC, or `Forget all` to clear every token and local session state. After rotating a Mac token, forget the old bridge entry and scan the new QR.

Implemented screens:

- Pairing screen with paste and QR scan flows.
- Multiple saved bridge reconnect, switch, and forget controls.
- Project screen with maludex branding, active thread, workspace path, connection status, streaming transcript, approval card, and prompt composer.
- Session sheet for model intelligence, auto context compaction, and safe permission changes.
- Touch-to-talk voice input and selectable/copyable transcript text.
- Subagent launcher that forks the current thread and starts an isolated turn.
- Diagnostics dashboard with copyable token-free bridge health reports.
- Truncation notice when an existing desktop chat history is too large for a single mobile response.
- Approval card with Approve and Deny only.

Git push and commit actions are intentionally not implemented.
