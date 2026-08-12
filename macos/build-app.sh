#!/usr/bin/env bash
# Build TorrentFlinger as a proper .app bundle so macOS treats it as a menubar
# accessory app (LSUIElement) and registers it as a magnet:// + .torrent
# handler. Output: ./TorrentFlinger.app
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-app.sh is macOS-only. The Linux app is its sibling:" >&2
    echo "  cd ../linux && ./scripts/setup.sh && ./bin/torrent-flinger" >&2
    exit 1
fi

CONFIG="${CONFIG:-release}"
APP_NAME="TorrentFlinger"
BUNDLE_ID="io.github.python2121.TorrentFlinger"
APP_DIR="${APP_NAME}.app"

cd "$(dirname "$0")"

# Commit this build was produced from, baked into Info.plist so a running app
# can identify itself in bug reports. Empty for non-git builds.
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"

# Load SIGN_IDENTITY (and any other local secrets) from .env if present.
if [[ -f .env ]]; then
  set -a; . ./.env; set +a
fi

# Optional tagged-release build (format vX.Y.Z) — bakes
# CFBundleShortVersionString from the tag. Unset by default.
RELEASE_TAG="${RELEASE_TAG:-}"
if [[ -n "${RELEASE_TAG}" ]]; then
  if [[ ! "${RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: RELEASE_TAG must match vX.Y.Z (got '${RELEASE_TAG}')" >&2
    exit 1
  fi
  VERSION_STRING="${RELEASE_TAG#v}"
  RELEASE_TAG_PLIST_ENTRY="  <key>ReleaseTag</key>
  <string>${RELEASE_TAG}</string>
"
else
  VERSION_STRING="0.1.0"
  RELEASE_TAG_PLIST_ENTRY=""
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# App icon, built from the shared PNG assets the Linux app already ships
# (../linux/flinger/assets). Optional: a missing/unbuildable icon is not fatal —
# the app just falls back to the generic bundle icon.
ICON_PLIST_ENTRY=""
ASSETS="../linux/flinger/assets"

# Menu-bar state glyphs. Monochrome SVG, shared verbatim with the Linux tray —
# AppKit tints them via isTemplate, Qt tints them by hand. Copied rather than
# compiled so both builds read exactly the same files.
for glyph in "${ASSETS}"/tray-*.svg; do
  [[ -f "$glyph" ]] && cp "$glyph" "${APP_DIR}/Contents/Resources/"
done
if [[ -f "${ASSETS}/icon128.png" ]] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "${ICONSET}"
  [[ -f "${ASSETS}/icon16.png"  ]] && cp "${ASSETS}/icon16.png"  "${ICONSET}/icon_16x16.png"
  [[ -f "${ASSETS}/icon32.png"  ]] && cp "${ASSETS}/icon32.png"  "${ICONSET}/icon_16x16@2x.png"
  [[ -f "${ASSETS}/icon32.png"  ]] && cp "${ASSETS}/icon32.png"  "${ICONSET}/icon_32x32.png"
  cp "${ASSETS}/icon128.png" "${ICONSET}/icon_128x128.png"
  if iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    ICON_PLIST_ENTRY="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
"
  else
    echo "==> note: iconutil failed; bundling without an app icon"
  fi
  rm -rf "$(dirname "${ICONSET}")"
fi

# CFBundleURLTypes registers us as a magnet: handler and CFBundleDocumentTypes
# as a .torrent opener — the macOS equivalent of the Linux
# x-scheme-handler/magnet + application/x-bittorrent desktop entry. Both are
# delivered to AppDelegate.application(_:open:).
cat >"${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>Torrent Flinger</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION_STRING}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
${ICON_PLIST_ENTRY}  <key>GitCommit</key>
  <string>${GIT_COMMIT}</string>
${RELEASE_TAG_PLIST_ENTRY}  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <!-- macOS 15+ gates connections to LAN hosts behind the Local Network
       privacy permission. Without this key the app can't be granted it, and
       every request to the server fails with NSURLErrorNotConnectedToInternet
       (-1009) — which surfaces as a bare "Disconnected" even though the same
       URL loads fine in a browser. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Torrent Flinger needs local network access to reach your Transmission server.</string>
  <!-- Transmission's RPC is plain http on a LAN in the overwhelmingly common
       case, which App Transport Security blocks by default (-1022). The Linux
       build talks to whatever you point it at, so this one does too. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Magnet Link</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>magnet</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>BitTorrent Metainfo</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>org.bittorrent.torrent</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Signing. Ad-hoc is the default and is genuinely fine here: rebuilds keep
# their Local Network permission (verified across rebuilds with distinct
# executable UUIDs), because LocalNetwork.requestAccess re-establishes access on
# every launch. Nothing else — no Keychain ACL, no Gatekeeper path — depends on
# a stable identity.
#
# Set SIGN_IDENTITY (env or .env), or create a certificate named
# "Torrent Flinger", and it'll be used instead. The only things that buys are a
# presentable name in System Settings → Login Items and a marginally smoother
# first poll after a rebuild.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Torrent Flinger"'; then
    SIGN_IDENTITY="Torrent Flinger"
  else
    SIGN_IDENTITY="-"
  fi
fi

echo "==> codesigning with identity: ${SIGN_IDENTITY}"
codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP_DIR}"

# A typo'd cert name would otherwise silently fall back to ad-hoc.
if [[ "${SIGN_IDENTITY}" != "-" ]] \
   && codesign -dvvv "${APP_DIR}" 2>&1 | grep -q "^Signature=adhoc$"; then
  echo "ERROR: signature is ad-hoc — identity '${SIGN_IDENTITY}' was not applied" >&2
  exit 1
fi

# Tell LaunchServices about the freshly built bundle so the magnet handler
# registration takes effect without a logout.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "${LSREGISTER}" ]] && "${LSREGISTER}" -f "$(pwd)/${APP_DIR}" || true

echo "==> done: $(pwd)/${APP_DIR}"
