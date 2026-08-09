#!/usr/bin/env bash
# Build and install the Flatpak (user-level, no root).
#
# Works on the SteamOS host or anywhere flatpak is available. Inside a
# distrobox this may fail if nested sandboxing (bwrap) is blocked — in that
# case run it on the host; the repo lives in shared $HOME so nothing changes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$HERE/packaging/flatpak/io.github.python2121.TorrentFlinger.yaml"

flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo

if command -v flatpak-builder >/dev/null 2>&1; then
    BUILDER=(flatpak-builder)
else
    flatpak install --user -y flathub org.flatpak.Builder
    BUILDER=(flatpak run org.flatpak.Builder)
fi

"${BUILDER[@]}" --user --install-deps-from=flathub --install --force-clean \
    "$HERE/.flatpak-build" "$MANIFEST"

echo
echo "Installed. Run with:  flatpak run io.github.python2121.TorrentFlinger"
echo "Magnet links now route to the Flatpak via its exported .desktop entry."
