#!/usr/bin/env bash
# Register Torrent Flinger as the system handler for magnet links and
# .torrent files, and optionally set it to start on login.
#
#   ./scripts/install-linux.sh [--autostart]
#
# Because your distrobox shares $HOME with the host, running this inside the
# box registers the handler for host browsers too (the launcher script
# re-enters the box automatically).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="$HOME/.local/share/applications"
DESKTOP="$APPS/torrent-flinger.desktop"

mkdir -p "$APPS"
sed -e "s|@ROOT@|$HERE|g" "$HERE/torrent-flinger.desktop.in" > "$DESKTOP"
chmod +x "$HERE/bin/torrent-flinger"

xdg-mime default torrent-flinger.desktop x-scheme-handler/magnet
xdg-mime default torrent-flinger.desktop application/x-bittorrent
update-desktop-database "$APPS" 2>/dev/null || true

echo "Installed $DESKTOP"
echo "magnet: links and .torrent files now open with Torrent Flinger."

if [ "${1:-}" = "--autostart" ]; then
    mkdir -p "$HOME/.config/autostart"
    sed -e 's|^Exec=\(.*\) %u$|Exec=\1|' "$DESKTOP" > "$HOME/.config/autostart/torrent-flinger.desktop"
    echo "Autostart on login enabled."
fi
