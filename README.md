# ClipTrail (macOS)

A practical clipboard history tool for macOS, built in Swift.

## Features

- Continuously watches clipboard changes
- Stores recent text clipboard history locally
- Native GUI mode
- **Global hotkey: Option + V** to show/hide window (Windows-like summon flow)
- List recent items quickly
- Copy any history item back to clipboard
- Clear history
- launchd template included for background auto-start

## Commands

```bash
cliptrail watch [--interval 0.8] [--max-items 500]
cliptrail gui
cliptrail list [--limit 30]
cliptrail copy --index <n>
cliptrail clear
cliptrail status
```

## Build locally (macOS)

```bash
swift build -c release
cp .build/release/cliptrail ./cliptrail
./cliptrail status
```

## Install locally

```bash
./scripts/install.sh
```

## Run watcher (CLI mode)

```bash
~/.local/bin/cliptrail watch --interval 0.8 --max-items 500
```

## Run GUI mode

```bash
~/.local/bin/cliptrail gui
```

## launchd (optional)

1. Edit `scripts/com.stanley.cliptrail.plist` and replace `/Users/REPLACE_ME` with your macOS username path.
2. Copy plist to `~/Library/LaunchAgents/`
3. Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.stanley.cliptrail.plist
```

Check status:

```bash
launchctl list | grep cliptrail
```

## GitHub Actions Build

On every push to `main` (and manual dispatch), GitHub Actions builds on **macOS** and uploads artifact:

- Artifact name: `cliptrail-macos`
- Contains:
  - `cliptrail` binary
  - `install.sh`
  - launchd plist template

## Notes

- Data path: `~/Library/Application Support/ClipTrail/history.json`
- This tool stores text clipboard history only.
