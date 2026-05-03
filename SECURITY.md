# Security Policy

maludex is a local-first MVP that lets a paired iPhone drive Codex running on a Mac through an authenticated bridge. Treat it as powerful local automation software.

## Supported Versions

Security fixes currently target the latest commit on `main`.

## Reporting A Vulnerability

Please open a private security advisory on GitHub if the repository settings allow it. If private advisories are not available, open a minimal public issue that describes the affected component without posting exploit details, bearer tokens, QR payloads, logs with prompts, or private file paths.

## Operational Warnings

- Do not expose the bridge through public router port forwarding.
- Use localhost for simulator testing or a private Tailscale IP for physical iPhone usage.
- Rotate the bearer token after demos, screenshots, or suspected exposure.
- Keep approval mode on request unless you fully understand the local risk.
- A paired and unlocked iPhone should be treated as a trusted device with access to recent transcript content and approval controls.
