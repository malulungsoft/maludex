# Changelog

## 0.1.1 - 2026-05-04

- Reconnect the iOS bridge after sleep, foreground resume, and stale WebSocket failures.
- Add lightweight heartbeat pings so dead sockets are detected without noisy alerts.
- Load chat transcripts newest-first and fetch older history pages only when scrolling upward.
- Add bridge integration coverage for cursor-based chat history loading.

## 0.1.0 - 2026-05-03

- Initial maludex bridge and iOS client MVP.
