# ClipTrail Technical Notes

## Architecture Overview

ClipTrail is a native macOS menu-bar clipboard manager built with:

- **SwiftUI** for UI
- **AppKit** for menu-bar/popup integration
- **Carbon HotKey API** for global shortcut registration (`Option + V`)
- **ServiceManagement** for launch-at-login support

## Runtime Model

- App runs as accessory app (`NSApplication.ActivationPolicy.accessory`)
- Main interaction surface is an `NSPopover` attached to menu-bar status item
- Clipboard polling interval: ~0.6s

## Data Model

Clipboard item types:

- `text`
- `image` (stored as PNG file path)
- `files` (array of local file paths)

Storage path:

- History JSON: `~/Library/Application Support/ClipTrail/history.json`
- Image cache: `~/Library/Application Support/ClipTrail/images/`

## Retention and Ordering

- Max history size: **1000** items
- Supports **pinned** items
- Sort order:
  1. pinned first
  2. then by timestamp descending

## Interaction Features

- Click row to copy item back to system clipboard
- Keyboard navigation:
  - `↑ / ↓` select
  - `Enter` copy selected
  - `Esc` close popup
- Toast feedback after copy

## Import / Export

- Export current history as JSON
- Import JSON and merge with existing history
- Import path includes dedupe by item fingerprint

## Auto Update (In-App)

- Checks latest release from GitHub API:
  `https://api.github.com/repos/stanley2312831/cliptrail/releases/latest`
- If newer version exists:
  - shows update banner
  - supports in-app DMG download/open

## Build & Packaging

CI: GitHub Actions (`build-macos.yml`)

Outputs:

- `ClipTrail.app`
- `ClipTrail.dmg`
- launchd plist helper file

DMG includes Applications shortcut for drag-drop install flow.

## Security / Privacy Notes

- Clipboard history is local-only (no remote sync)
- Update check accesses GitHub API and release assets
- Clipboard may include sensitive data; user should clear history periodically

## Attribution

Maintainer: **Telegram @STANLEY_LEGEND**
