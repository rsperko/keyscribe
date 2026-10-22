#!/usr/bin/env bash
# Build the package and its tests with the oldest supported Xcode (BUILD.md), installed beside the current one.
# A newer compiler accepts code an older one rejects, and no language-mode flag reproduces the older compiler,
# so the only check is to run it. Downstream builds with that Xcode; without this, it finds the break first.
#
#   scripts/check-min-xcode.sh
#
# The Xcode is found by the version it reports, never by its file name, and nothing else is accepted:
# KEYSCRIBE_MIN_XCODE narrows the search to one app but cannot change the version required. The build directory
# lives outside the checkout so the two compilers never share a cache, and is kept between runs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRED_XCODE="26.6"
SCRATCH="${KEYSCRIBE_MIN_XCODE_BUILD_DIR:-$HOME/Library/Caches/keyscribe-min-xcode}"
LIMIT="${KEYSCRIBE_MIN_XCODE_TIMEOUT:-2400}"

xcode_version() { DEVELOPER_DIR="$1/Contents/Developer" xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }'; }

XCODE=""
seen=()
if [ -n "${KEYSCRIBE_MIN_XCODE:-}" ]; then candidates=("$KEYSCRIBE_MIN_XCODE"); else candidates=(/Applications/Xcode*.app); fi
for app in "${candidates[@]}"; do
  [ -d "$app/Contents/Developer" ] || continue
  version="$(xcode_version "$app")"
  seen+=("$app ($version)")
  case "$version" in "$REQUIRED_XCODE"|"$REQUIRED_XCODE".*) XCODE="$app"; break ;; esac
done
if [ -z "$XCODE" ]; then
  echo "!! No Xcode $REQUIRED_XCODE found. Checked: ${seen[*]:-nothing}" >&2
  echo "   Download it from https://developer.apple.com/download/all/ , expand the .xip, and move the app into" >&2
  echo "   /Applications under any Xcode*.app name. Leave xcode-select pointing at the current Xcode." >&2
  exit 2
fi
command -v timeout >/dev/null 2>&1 || { echo "!! GNU timeout not found — brew install coreutils" >&2; exit 2; }

export DEVELOPER_DIR="$XCODE/Contents/Developer"
echo "Building with $XCODE (Xcode $(xcode_version "$XCODE"))"
xcrun swift --version 2>&1 | head -1
build_system=""
if xcrun swift build --help 2>/dev/null | grep -q -- '--build-system'; then build_system="--build-system native"; fi
cd "$ROOT"
# shellcheck disable=SC2086  # deliberate split: either empty or the two flag tokens
timeout --foreground "$LIMIT" xcrun swift build --build-tests --scratch-path "$SCRATCH" $build_system
