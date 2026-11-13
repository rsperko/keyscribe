#!/usr/bin/env bash
# Fill FluidAudioRevision in the built app's Info.plist from the build's lockfile when the build invocation did
# not pass KEYSCRIBE_FLUIDAUDIO_REVISION, so the spoken-audio report always names the voice library that made
# the audio. Runs as the app target's post-build phase (App/template.yml), before Xcode signs the bundle.
#
#   scripts/stamp-dependency-revisions.sh [<path/to/App.app> [<Package.resolved>]]
#
# With no arguments it takes the product at $TARGET_BUILD_DIR/$WRAPPER_NAME and the lockfile in
# $PROJECT_FILE_PATH, the same places scripts/collect-licenses.sh reads. A revision the invocation passed (the
# KEYSCRIBE_FLUIDAUDIO_REVISION build setting) is left alone; otherwise the lockfile's pin is written every build, so
# an incremental build after a pin bump never keeps an earlier stamp. A lockfile without a FluidAudio pin leaves
# "unknown".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}}"
PROJECT_LOCKFILE="${PROJECT_FILE_PATH:+$PROJECT_FILE_PATH/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}"
LOCKFILE="${2:-${PROJECT_LOCKFILE:-$ROOT/Package.resolved}}"
PLIST="$APP/Contents/Info.plist"

[ -f "$PLIST" ] || { echo "error: Info.plist not found: $PLIST" >&2; exit 1; }

PASSED="${KEYSCRIBE_FLUIDAUDIO_REVISION:-unknown}"
if [ "$PASSED" != "unknown" ]; then exit 0; fi
[ -f "$LOCKFILE" ] || { echo "warning: no lockfile at $LOCKFILE; FluidAudioRevision stays unknown" >&2; exit 0; }

REVISION="$(python3 - "$LOCKFILE" <<'PY'
import json, sys
pins = {p["identity"]: p.get("state", {}) for p in json.load(open(sys.argv[1]))["pins"]}
state = pins.get("fluidaudio", {})
revision = state.get("revision", "")
version = state.get("version")
print(f"{revision} ({version})" if revision and version else revision)
PY
)"
[ -n "$REVISION" ] || exit 0
/usr/libexec/PlistBuddy -c "Delete :FluidAudioRevision" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :FluidAudioRevision string $REVISION" "$PLIST"
