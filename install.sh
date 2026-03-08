#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.local/bin/openclaw-secret"

mkdir -p "$HOME/.local/bin"
chmod +x "$SCRIPT_DIR/openclaw-secret"
ln -sf "$SCRIPT_DIR/openclaw-secret" "$TARGET"

echo "✓ Installed: $TARGET -> $SCRIPT_DIR/openclaw-secret"
echo ""
echo "Make sure ~/.local/bin is in your PATH."
echo "Usage: openclaw-secret help"
