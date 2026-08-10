#!/usr/bin/env bash
# Build (unless SKIP_BUILD=1), stop any running instance, replace the bundle
# in /Applications, and restart. Idempotent — safe to re-run after every code
# change.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "install.sh is macOS-only. For Linux see ../scripts/install-linux.sh" >&2
    exit 1
fi

cd "$(dirname "$0")"

APP_NAME="TorrentFlinger"
APP_BUNDLE="${APP_NAME}.app"
DEST="/Applications/${APP_BUNDLE}"
LABEL="io.github.python2121.TorrentFlinger"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  ./build-app.sh
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "ERROR: ${APP_BUNDLE} not built — run ./build-app.sh first" >&2
  exit 1
fi

# Stop the LaunchAgent first so launchd doesn't respawn the old binary
# mid-replace. If it's not loaded, this is a no-op.
if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
  echo "==> stopping LaunchAgent"
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
fi

# Belt-and-braces — covers manually-launched instances not under launchd.
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "==> killing running ${APP_NAME}"
  pkill -x "${APP_NAME}" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "==> ${APP_NAME} didn't exit, sending SIGKILL"
    pkill -9 -x "${APP_NAME}" || true
    sleep 0.5
  fi
fi

echo "==> installing to ${DEST}"
rm -rf "${DEST}"
cp -R "${APP_BUNDLE}" "${DEST}"

if ! codesign --verify --verbose=1 "${DEST}" >/dev/null 2>&1; then
  echo "ERROR: ${DEST} fails signature verification after install" >&2
  exit 1
fi

# Re-register the installed copy so magnet: links resolve to /Applications
# rather than the build directory.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "${LSREGISTER}" ]] && "${LSREGISTER}" -f "${DEST}" || true

# Start it. Prefer the LaunchAgent if the user has set one up — that way
# launchd will keep it alive and restart it on crash. Otherwise just open.
if [[ -f "${PLIST}" ]]; then
  echo "==> bootstrapping LaunchAgent"
  launchctl bootstrap "gui/${UID_NUM}" "${PLIST}"
else
  echo "==> opening ${DEST}"
  open "${DEST}"
fi

sleep 1
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "==> done — ${APP_NAME} running (pid $(pgrep -x ${APP_NAME}))"
else
  echo "WARNING: ${APP_NAME} doesn't appear to be running. Check /tmp/torrentflinger.err.log" >&2
  exit 1
fi
