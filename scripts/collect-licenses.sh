#!/usr/bin/env bash
# Copy the GPLv3 LICENSE, THIRD-PARTY-NOTICES.md, and the LICENSE*/NOTICE* files of every package pinned in
# the build's lockfile into <app>/Contents/Resources/Legal. Runs as the app target's post-build phase
# (App/template.yml). It walks the lockfile, not the checkouts directory, so a checkout left behind by an
# earlier dependency graph never ships its notice.
#
#   scripts/collect-licenses.sh [<path/to/App.app> <path/to/SourcePackages/checkouts> [<Package.resolved>]]
#
# With no arguments it takes everything from Xcode's build-phase environment: the product at
# $TARGET_BUILD_DIR/$WRAPPER_NAME, the checkouts under the derived data's SourcePackages (found by walking
# up from $BUILD_DIR; a plain build puts it two levels up, an archive several more), and the lockfile in
# $PROJECT_FILE_PATH. A CI that resolves packages elsewhere (`-clonedSourcePackagesDirPath`) sets
# KEYSCRIBE_SPM_CHECKOUTS instead. Run by hand without a lockfile, it reads the root Package.resolved.
#
# Every pin must have a checkout holding at least one LICENSE* or NOTICE* file, or this fails naming the pin:
# the artifact would otherwise ship without required attribution. Sparkle is skipped when the binary does not
# link it, since it is resolved for every build but linked only by the public app. A pin's checkout directory
# is its repository name: the last component of its location, without `.git`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}}"

find_checkouts() {
  local dir="${BUILD_DIR:-}"
  local depth=0
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ $depth -lt 10 ]; do
    if [ -d "$dir/SourcePackages/checkouts" ]; then echo "$dir/SourcePackages/checkouts"; return; fi
    dir="$(dirname "$dir")"; depth=$((depth + 1))
  done
}
CHECKOUTS="${2:-${KEYSCRIBE_SPM_CHECKOUTS:-$(find_checkouts)}}"
PROJECT_LOCKFILE="${PROJECT_FILE_PATH:+$PROJECT_FILE_PATH/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}"
LOCKFILE="${3:-${PROJECT_LOCKFILE:-$ROOT/Package.resolved}}"

[ -d "$APP" ] || { echo "error: app bundle not found: $APP" >&2; exit 1; }
[ -d "$CHECKOUTS" ] || { echo "error: SwiftPM checkouts not found: $CHECKOUTS" >&2; exit 1; }
[ -f "$LOCKFILE" ] || { echo "error: lockfile not found: $LOCKFILE" >&2; exit 1; }

LEGAL="$APP/Contents/Resources/Legal"
DEPS="$LEGAL/Dependencies"
rm -rf "$LEGAL"
mkdir -p "$DEPS"
cp "$ROOT/LICENSE" "$LEGAL/LICENSE"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$LEGAL/THIRD-PARTY-NOTICES.md"

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
LINKS_SPARKLE=0
if otool -L "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null | grep -q "Sparkle.framework"; then LINKS_SPARKLE=1; fi

PINS="$(python3 - "$LOCKFILE" <<'PY'
import json, os, sys
for pin in json.load(open(sys.argv[1]))["pins"]:
    name = os.path.basename(pin["location"].rstrip("/"))
    if name.endswith(".git"):
        name = name[:-len(".git")]
    print(f'{pin["identity"]}\t{name}')
PY
)"

while IFS=$'\t' read -r identity name; do
  [ -n "$identity" ] || continue
  if [ "$identity" = "sparkle" ] && [ "$LINKS_SPARKLE" = 0 ]; then continue; fi
  checkout="$CHECKOUTS/$name"
  [ -d "$checkout" ] || { echo "error: $identity: no checkout at $checkout" >&2; exit 1; }
  copied=0
  for notice in "$checkout"/LICENSE* "$checkout"/NOTICE*; do
    [ -f "$notice" ] || continue
    cp "$notice" "$DEPS/$name-$(basename "$notice")"
    copied=1
  done
  [ "$copied" = 1 ] || { echo "error: $identity: no LICENSE or NOTICE file in $checkout" >&2; exit 1; }
done <<< "$PINS"

echo "Legal notices: $(ls "$DEPS" | wc -l | tr -d ' ') dependency files"
