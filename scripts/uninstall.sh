#!/bin/bash
# Removes Islandly, the notch command, and (optionally) its settings and permissions.
#   ./scripts/uninstall.sh            keep settings
#   ./scripts/uninstall.sh --all      also delete settings and reset privacy permissions
set -uo pipefail
pkill -x Islandly 2>/dev/null
for app in /Applications/Islandly.app "$HOME/Applications/Islandly.app"; do
    [ -d "$app" ] && rm -rf "$app" && echo "Removed $app"
done
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    [ -L "$d/notch" ] && rm -f "$d/notch" && echo "Removed $d/notch"
done
if [ "${1:-}" = "--all" ]; then
    defaults delete app.islandly 2>/dev/null && echo "Deleted settings"
    tccutil reset All app.islandly >/dev/null 2>&1 && echo "Reset privacy permissions"
fi
echo "Islandly uninstalled."
