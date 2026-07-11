#!/usr/bin/env bash
# UI-test runner for the XCUITest suite (UITests/). Splits the slow, RE-SIGNING build from the fast run so
# the runner's code signature -- and therefore its one-time Accessibility grant -- stays stable across
# iterations. A teamless self-signed runner is keyed in TCC by CDHash, so every re-sign re-prompts "Allow".
# Build once, grant once, then run many times without re-signing (no more prompts until the next build).
#
#   ui-test.sh build            (re)generate the project + build-for-testing, then print the runner path to grant
#   ui-test.sh grant            reveal the runner in Finder + open the Accessibility settings pane
#   ui-test.sh run [args...]    test-without-building (reuses the signed runner); extra args go to xcodebuild
#   ui-test.sh all  [args...]   build then run (re-signs -> may re-prompt once)
#
# Common: ui-test.sh run -only-testing:KeyScribeUITests/SidebarNavigationTests
# Prereq: KeyScribeDev.app built (./make-app.sh) -- the tests drive the prebuilt app by bundle id.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UITESTS="$ROOT/UITests"
PROJECT="$UITESTS/KeyScribeUITests.xcodeproj"
SCHEME="KeyScribeUITests"
DD="$UITESTS/DerivedData"
RUNNER="$DD/Build/Products/Debug/KeyScribeUITests-Runner.app"
DEST='platform=macOS'
SIGN=(CODE_SIGN_IDENTITY="KeyScribe Local" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")

require_app() {
  [ -d "$ROOT/KeyScribeDev.app" ] || {
    echo "KeyScribeDev.app not found -- build it first: ./make-app.sh (or make build)"; exit 1; }
}

do_build() {
  command -v xcodegen >/dev/null || { echo "xcodegen not found -- brew install xcodegen"; exit 1; }
  ( cd "$UITESTS" && xcodegen generate )
  xcodebuild build-for-testing -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DEST" -derivedDataPath "$DD" "${SIGN[@]}"
  echo
  echo "Built. Grant the runner Accessibility ONCE (holds until the next 'build'):"
  echo "  $RUNNER"
  echo "  scripts/ui-test.sh grant   # reveal it + open the settings pane"
}

do_grant() {
  [ -d "$RUNNER" ] || { echo "Runner not built yet -- run: scripts/ui-test.sh build"; exit 1; }
  open -R "$RUNNER"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  echo "Add to Accessibility (+ button, then Cmd-Shift-G and paste):"
  echo "  $RUNNER"
}

do_run() {
  require_app
  [ -d "$RUNNER" ] || { echo "No built runner -- run: scripts/ui-test.sh build (then grant)"; exit 1; }
  pkill -9 -f "KeyScribeDev.app/Contents/MacOS/" 2>/dev/null || true
  sleep 1
  xcodebuild test-without-building -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DEST" -derivedDataPath "$DD" "$@"
}

case "${1:-run}" in
  build)  do_build ;;
  grant)  do_grant ;;
  run)    shift || true; do_run "$@" ;;
  all)    shift || true; do_build; do_run "$@" ;;
  *)      echo "usage: ui-test.sh {build|grant|run|all} [xcodebuild args...]" >&2; exit 2 ;;
esac
