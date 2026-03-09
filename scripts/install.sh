#!/usr/bin/env bash
set -euo pipefail
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cp ./cliptrail "$BIN_DIR/cliptrail"
chmod +x "$BIN_DIR/cliptrail"
echo "Installed to $BIN_DIR/cliptrail"
echo "Add to PATH if needed: export PATH=\"$BIN_DIR:$PATH\""
