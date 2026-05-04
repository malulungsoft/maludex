# Release Process

maludex releases are tag-driven. The local release script verifies version
strings, runs the bridge and iOS checks, and can push the branch plus tag.

## Prepare

1. Update `CHANGELOG.md`.
2. Bump all version strings with the target version.
3. Keep private local files out of the commit, especially tokens, QR payloads,
   Xcode signing metadata, and `.codex-mobile-attachments/`.

## Verify Locally

```bash
./scripts/release.sh v0.4.0 --check-only
```

The check runs:

- `npm ci`
- `npm run build`
- `npm test`
- Swift model tests
- Swift transcript tests
- Xcode iOS Simulator build

## Tag And Push

```bash
./scripts/release.sh v0.4.0 --push
```

Pushing a `v*` tag triggers the GitHub Release workflow. Release notes are
extracted from the matching `CHANGELOG.md` section.
