#!/usr/bin/env bash
# Nuclear permission reset. Wipes every TCC grant KeyScribe uses, then relaunches the app straight
# into a guided, one-at-a-time re-grant. Use after a botched/ad-hoc rebuild left stale grants that
# show as "on" in System Settings but read as denied (and silently suppress each other's prompts).
#
# Optional first arg: path to KeyScribe.app (defaults to the repo's built bundle).
set -euo pipefail

BUNDLE_ID="com.keyscribe.app"
APP_NAME="KeyScribe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-${SCRIPT_DIR}/../${APP_NAME}.app}"

echo "== Quitting ${APP_NAME} (so it re-reads permissions on next launch) =="
osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1

echo "== Wiping TCC grants for ${BUNDLE_ID} =="
# Reset all three together. A stale grant on one service makes TCC skip another service's consent
# prompt ("already authorized"), so a partial reset leaves the dialog silently broken.
for service in Microphone ListenEvent Accessibility; do
  if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "   reset ${service}"
  else
    echo "   reset ${service} (no existing record)"
  fi
done

if [ ! -d "$APP" ]; then
  echo "! ${APP} not found — build it (./make-app.sh) then re-run, or pass the path as an argument." >&2
  echo "  Grants are already cleared; launch KeyScribe and grant when prompted." >&2
  exit 0
fi

echo "== Relaunching into guided permission setup =="
open -n "$APP" --args --setup-permissions

cat <<'EOF'
Done. In the window that opens, grant in order:
  1. Microphone        (one click, applies immediately)
  2. Input Monitoring  (toggle KeyScribe on in System Settings when it opens)
  3. Accessibility     (toggle KeyScribe on in System Settings when it opens)
Then click "Quit & Relaunch to Apply" — Input Monitoring and Accessibility only take
effect after that relaunch. The app comes back with all three granted.
EOF
