# Changelog

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
