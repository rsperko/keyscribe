#!/usr/bin/env bash
# Shared front half of every app build (make-app.sh, release.sh, and a downstream distribution's build):
# check the toolchain, generate the Xcode project from an XcodeGen spec, and seed the project's lockfile.
# Callers then run xcodebuild with `-disableAutomaticPackageResolution -xcconfig App/Config/Packages.xcconfig`
# plus the version settings this script prints on stdout (one KEY=value per line, ready to splice onto the
# xcodebuild command).
#
#   scripts/prepare-xcode-project.sh [--spec <project.yml>] [--project-dir <dir>] [--lockfile <Package.resolved>]
#
# The defaults build upstream: App/project.yml into App/, seeded from the root Package.resolved. A downstream
# distribution passes its own spec, project directory, and committed lockfile (upstream's pins plus its own
# packages' pins). Every pin in upstream's Package.resolved must appear in that lockfile at the same
# revision, or this fails naming the first one that differs, before anything is generated.
#
# Frozen resolution alone is not the guard: `-disableAutomaticPackageResolution` rejects a lockfile that
# violates the manifest but silently keeps one that merely drifted inside a version range. Copying the
# lockfile in before every build is what keeps the Xcode graph identical to `swift build`'s.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "$@" >&2; }
absolute() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

SPEC="$ROOT/App/project.yml"
PROJECT_DIR="$ROOT/App"
LOCKFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)        SPEC="$(absolute "${2:?--spec needs a path}")"; shift 2 ;;
    --project-dir) PROJECT_DIR="$(absolute "${2:?--project-dir needs a path}")"; shift 2 ;;
    --lockfile)    LOCKFILE="$(absolute "${2:?--lockfile needs a path}")"; shift 2 ;;
    *)
      log "usage: $(basename "$0") [--spec <project.yml>] [--project-dir <dir>] [--lockfile <Package.resolved>]"
      exit 2 ;;
  esac
done
cd "$ROOT"

# Toolchain preflight: fail in seconds with the fix, not minutes in with a wall of compile errors.
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  log "!! KeyScribe builds only on Apple-silicon macOS (arm64). Host is $(uname -s)/$(uname -m)."
  log "!! The speech engines (FluidAudio / MLX / CoreML) have no x86_64 or non-macOS build."
  exit 1
fi
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEVDIR" in
  "")
    log "!! No Xcode toolchain selected. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
    exit 1 ;;
  *CommandLineTools*)
    log "!! xcode-select points at the Command Line Tools ($DEVDIR), not full Xcode."
    log "!! The CLT ship no xcodebuild, no Metal compiler, and no SwiftUI macro plugins."
    log "!! Fix: sudo xcode-select -s /Applications/Xcode.app"
    exit 1 ;;
esac
command -v xcodegen >/dev/null 2>&1 || { log "!! xcodegen not found — brew install xcodegen"; exit 1; }
# Xcode compiles MLX's Metal shaders as part of the package build, so the Metal Toolchain is required.
# `xcrun -f metal` finds Xcode 26's "missing Metal Toolchain" stub whether or not it is installed, so
# compile a one-line kernel instead.
PROBE_DIR="$(mktemp -d)"
printf 'kernel void probe(uint i [[thread_position_in_grid]]) { (void)i; }\n' > "$PROBE_DIR/probe.metal"
if ! xcrun -sdk macosx metal -c "$PROBE_DIR/probe.metal" -o "$PROBE_DIR/probe.air" >"$PROBE_DIR/metal.err" 2>&1; then
  cat "$PROBE_DIR/metal.err" >&2
  log "!! The Metal Toolchain cannot compile shaders, and Qwen3-ASR cannot run without them."
  log "!! run: xcodebuild -downloadComponent MetalToolchain"
  rm -rf "$PROBE_DIR"
  exit 1
fi
rm -rf "$PROBE_DIR"

if [ -n "$LOCKFILE" ]; then
  [ -f "$LOCKFILE" ] || { log "!! lockfile not found: $LOCKFILE"; exit 1; }
  if ! MISMATCH="$(python3 - "$ROOT/Package.resolved" "$LOCKFILE" <<'PY'
import json, sys
def revisions(path):
    return {pin["identity"]: pin["state"].get("revision") for pin in json.load(open(path))["pins"]}
upstream, given = revisions(sys.argv[1]), revisions(sys.argv[2])
for identity, revision in upstream.items():
    if given.get(identity) != revision:
        print(f"{identity}: upstream pins {revision}, this lockfile has {given.get(identity) or 'no pin'}")
        sys.exit(1)
PY
  )"; then
    log "!! $LOCKFILE does not match upstream's pins: ${MISMATCH:-could not read it}"
    log "!! Update those pins to upstream's Package.resolved revisions, keep your own packages' pins, and re-run."
    exit 1
  fi
fi

PROJECT_NAME="$(sed -n 's/^name:[[:space:]]*//p' "$SPEC" | head -1 | tr -d "\"'")"
[ -n "$PROJECT_NAME" ] || { log "!! no top-level 'name:' in $SPEC"; exit 1; }
log "== generating $PROJECT_DIR/$PROJECT_NAME.xcodeproj =="
xcodegen generate --spec "$SPEC" --project "$PROJECT_DIR" --quiet
LOCK_DIR="$PROJECT_DIR/$PROJECT_NAME.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$LOCK_DIR"
cp "${LOCKFILE:-$ROOT/Package.resolved}" "$LOCK_DIR/Package.resolved"

# Version stamped into Info.plist: marketing version from git tags, build number from the monotonic
# commit count (Sparkle orders updates by build number, not the marketing string), plus the exact commit.
# A build cut exactly on a tag reads clean ("0.1.0"); an untagged build gets the full describe
# ("0.1.0-2-gc1dc4af", "-dirty" with uncommitted changes) so it can never be mistaken for the release.
# Explicit KEYSCRIBE_VERSION / KEYSCRIBE_BUILD / KEYSCRIBE_SCM_REVISION win, so a mirror whose git history
# is not this repo's can pass its own; the git fallbacks cover a non-git tarball.
SHORT_VERSION="${KEYSCRIBE_VERSION:-$(git describe --tags --dirty 2>/dev/null | sed 's/^v//' || true)}"
[ -z "$SHORT_VERSION" ] && SHORT_VERSION="0.1"
BUILD_VERSION="${KEYSCRIBE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || true)}"
[ -z "$BUILD_VERSION" ] && BUILD_VERSION="1"
SCM_REVISION="${KEYSCRIBE_SCM_REVISION:-$(git rev-parse HEAD 2>/dev/null || true)}"
[ -z "$SCM_REVISION" ] && SCM_REVISION="unknown"
log "== version $SHORT_VERSION (build $BUILD_VERSION), scm $SCM_REVISION =="

printf 'MARKETING_VERSION=%s\nCURRENT_PROJECT_VERSION=%s\nKEYSCRIBE_SCM_REVISION=%s\n' \
  "$SHORT_VERSION" "$BUILD_VERSION" "$SCM_REVISION"
