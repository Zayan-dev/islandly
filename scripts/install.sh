#!/bin/bash
# One-step install for developers: build → Applications → `notch` command → launch.
#   ./scripts/install.sh
# Overrides: ISLANDLY_APP_DIR (default /Applications, or ~/Applications if not writable),
#            ISLANDLY_BIN_DIR (where the `notch` symlink goes), NO_OPEN=1 (don't launch).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

echo "▸ Building Islandly for this Mac…"
ARCHS="${ARCHS:-$(uname -m)}" ./build.sh | tail -2

APP_DIR="${ISLANDLY_APP_DIR:-/Applications}"
[ -w "$APP_DIR" ] || APP_DIR="$HOME/Applications"
mkdir -p "$APP_DIR"
echo "▸ Installing to $APP_DIR/Islandly.app"
pkill -x Islandly 2>/dev/null || true
rm -rf "$APP_DIR/Islandly.app"
cp -R build/Islandly.app "$APP_DIR/"

# `notch` command: symlink into the first writable bin dir on PATH (Homebrew's usually is).
BIN_DIR="${ISLANDLY_BIN_DIR:-}"
if [ -z "$BIN_DIR" ]; then
    for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
        if [ -d "$d" ] && [ -w "$d" ]; then BIN_DIR="$d"; break; fi
    done
fi
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
ln -sf "$REPO/bin/notch" "$BIN_DIR/notch"
echo "▸ Linked the notch command → $BIN_DIR/notch"

[ "${NO_OPEN:-0}" = "1" ] || open "$APP_DIR/Islandly.app"

echo
echo "✅ Islandly is running — hover over your notch."
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "   Add notch to your PATH:  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
echo "   Start at login: System Settings → General → Login Items → + → Islandly"
