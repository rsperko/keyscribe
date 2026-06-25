#!/usr/bin/env bash
# Nuclear permission reset. Wipes every TCC grant KeyScribe uses, then relaunches the app straight
# into a guided, one-at-a-time re-grant. Use after a botched/ad-hoc rebuild left stale grants that
# show as "on" in System Settings but read as denied (and silently suppress each other's prompts).
#
# Targets the dev build by default (KEYSCRIBE_VARIANT=release to target the production install).
# Optional first arg: explicit path to the .app bundle (overrides the variant default).
set -euo pipefail

# Variant selects which install's grants to wipe. Default dev — this is dev tooling. The executable
# inside the bundle is named "KeyScribe" for both variants; only the bundle/name/id differ.
case "${KEYSCRIBE_VARIANT:-dev}" in
  release|prod|production) APP_NAME="KeyScribe";    BUNDLE_ID="com.keyscribe.app" ;;
  dev|*)                   APP_NAME="KeyScribeDev"; BUNDLE_ID="com.keyscribe.app.dev" ;;
esac
EXECUTABLE="KeyScribe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-${SCRIPT_DIR}/../${APP_NAME}.app}"

echo "== Quitting ${APP_NAME} (so it re-reads permissions on next launch) =="
osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
pkill -f "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true
sleep 1

echo "== Wiping TCC grants for ${BUNDLE_ID} =="
# Reset both together. A stale grant on one service makes TCC skip another service's consent
# prompt ("already authorized"), so a partial reset leaves the dialog silently broken.
for service in Microphone Accessibility; do
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
  1. Microphone     (one click, applies immediately)
  2. Accessibility  (toggle KeyScribe on in System Settings when it opens)
Then click "Quit & Relaunch to Apply" — Accessibility only takes
effect after that relaunch. The app comes back with both granted.
EOF
