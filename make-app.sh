#!/usr/bin/env bash
# Build KeyScribe into a signed KeyScribe.app (LSUIElement menu-bar app) so TCC permissions
# (Microphone / Accessibility) attach to a stable signed identity and
# survive rebuilds. Signs with a stable cert if one is found, else ad-hoc (TCC may reset).
# Full from-source build / signing guide: BUILD.md.
set -euo pipefail
cd "$(dirname "$0")"

APP="KeyScribe.app"
BIN=".build/release/KeyScribe"
CONFIG="${1:-release}"

# Preflight: catch the failure modes a fresh clone hits — wrong arch, missing or Command-Line-Tools-
# only Xcode, absent Metal Toolchain — up front with an actionable message, instead of a cryptic
# error minutes into the build. Only a non-arm64 / non-macOS host is fatal; everything else (which
# only affects the optional MLX-based Qwen3-ASR engine) warns and continues. Full guide: BUILD.md.
echo "== preflight =="
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "!! KeyScribe builds only on Apple-silicon macOS (arm64). Host is $(uname -s)/$(uname -m)." >&2
  echo "!! The speech engines (FluidAudio / MLX / CoreML) have no x86_64 or non-macOS build." >&2
  exit 1
fi
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$DEVDIR" ]; then
  echo "!! No Xcode toolchain selected. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi
case "$DEVDIR" in
  *CommandLineTools*)
    echo "warning: xcode-select points at the Command Line Tools ($DEVDIR), not full Xcode." >&2
    echo "         Select Xcode for Metal/Qwen3-ASR: sudo xcode-select -s /Applications/Xcode.app" >&2
    ;;
esac
if ! xcrun -f metal >/dev/null 2>&1; then
  echo "warning: Metal Toolchain not installed — Qwen3-ASR will be unavailable (other engines work)." >&2
  echo "         Install it once with: xcodebuild -downloadComponent MetalToolchain" >&2
fi
# Swift floor is enforced by Package.swift's swift-tools-version (swift build refuses an older
# toolchain on its own) — we don't re-gate it here. This is only an informational breadcrumb: print
# the verified-good toolchain next to what's installed, so if a toolchain-specific compiler bug ever
# breaks the build, the next person has the clue to update Xcode. Never blocks.
SWIFT_TESTED="6.3"
SWIFT_VER="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [ -n "$SWIFT_VER" ]; then
  echo "Swift $SWIFT_VER detected (build verified on $SWIFT_TESTED)."
  if [ "$(printf '%s\n%s\n' "$SWIFT_TESTED" "$SWIFT_VER" | sort -V | head -1)" != "$SWIFT_TESTED" ]; then
    echo "note: older than the verified toolchain — if the build fails with a compiler error, update Xcode." >&2
  fi
fi

# Version stamped into Info.plist: marketing version from git tags, build number from the
# monotonic commit count (Sparkle orders updates by build number, not the marketing string).
# A build cut exactly on a tag reads clean ("0.1.0"); an untagged dev build gets the full describe
# ("0.1.0-2-gc1dc4af", "-dirty" when the tree has uncommitted changes) so it can never be mistaken
# for the release. Both fall back when built from a non-git tarball.
SHORT_VERSION="$(git describe --tags --dirty 2>/dev/null | sed 's/^v//' || true)"
[ -z "$SHORT_VERSION" ] && SHORT_VERSION="0.1"
BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || true)"
[ -z "$BUILD_VERSION" ] && BUILD_VERSION="1"

echo "== building KeyScribe ($CONFIG) =="
swift build -c "$CONFIG" --product KeyScribe
[ "$CONFIG" = "debug" ] && BIN=".build/debug/KeyScribe"

# Qwen3-ASR runs on MLX, which hard-fails ("Failed to load the default metallib") without
# mlx.metallib next to the executable. Build it from the speech-swift checkout's kernels and bundle
# it into the .app below. Non-fatal: the other engines (Parakeet/Whisper/Apple) don't need it, so a
# missing Metal Toolchain warns instead of blocking the build. Install it with:
#   xcodebuild -downloadComponent MetalToolchain
echo "== building mlx.metallib (required by Qwen3-ASR) =="
METALLIB_SCRIPT=".build/checkouts/speech-swift/scripts/build_mlx_metallib.sh"
if [ -f "$METALLIB_SCRIPT" ]; then
  BUILD_DIR="$(pwd)/.build" bash "$METALLIB_SCRIPT" "$CONFIG" \
    || echo "warning: metallib build failed — Qwen3-ASR will crash at runtime (other engines unaffected)" >&2
else
  echo "warning: $METALLIB_SCRIPT not found — run swift build first; Qwen3-ASR needs mlx.metallib" >&2
fi

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KeyScribe"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# MLX loads mlx.metallib from next to the executable — place it in MacOS/, beside the binary.
METALLIB=".build/$CONFIG/mlx.metallib"
if [ -f "$METALLIB" ]; then
  cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"
else
  echo "warning: $METALLIB missing — Qwen3-ASR will crash at runtime" >&2
fi
# Bundled model self-test clip (loaded via Bundle.main at runtime).
cp Resources/model-selftest.wav "$APP/Contents/Resources/model-selftest.wav"
# First-party "now listening" start cue (loaded via Bundle.main at runtime).
cp Resources/start-cue.wav "$APP/Contents/Resources/start-cue.wav"
# Info.plist is a tracked source file (Resources/Info.plist); stamp the git-derived version into it.
echo "== Info.plist: $SHORT_VERSION (build $BUILD_VERSION) =="
sed -e "s/__SHORT_VERSION__/$SHORT_VERSION/" -e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

# Stable-identity signing keeps TCC grants (Mic / Accessibility) across rebuilds.
# macOS TCC only needs a *valid, stable* signature — a self-signed cert works; no Apple account is
# required. See BUILD.md for the one-time "create a self-signed cert named KeyScribe Local" steps.
# Identity precedence: KEYSCRIBE_SIGN_ID, then CODESIGN_IDENTITY (conventional name), then auto-detect
# the project cert "KeyScribe Local" (BUILD.md has create-it steps), else ad-hoc ("-", which works but
# may reset TCC each rebuild). For any other cert, pass it via KEYSCRIBE_SIGN_ID/CODESIGN_IDENTITY.
# Signing with a real cert prompts once for keychain access — run from your terminal and click "Always
# Allow". Sign inner Mach-O then the bundle (no --deep: Swift linker-signs the binary and --deep
# mishandles it).
ID="${KEYSCRIBE_SIGN_ID:-${CODESIGN_IDENTITY:-}}"
if [ -z "$ID" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "KeyScribe Local"; then
    ID="KeyScribe Local"
  else
    ID="-"
  fi
fi
find "$APP" -name "*.cstemp" -delete 2>/dev/null || true
if [ "$ID" = "-" ]; then
  echo "!! AD-HOC signing — no stable cert found. TCC grants (Microphone /" >&2
  echo "!! Accessibility) will NOT survive this rebuild; toggling them on will not stick." >&2
  echo "!! Fix once: ./scripts/setup-dev-signing.sh  (creates 'KeyScribe Local'), then rebuild." >&2
  echo "!! Already broken? ./scripts/reset-permissions.sh wipes and re-grants cleanly. See BUILD.md." >&2
else
  echo "== signing with: $ID =="
fi
# mlx.metallib sits in MacOS/ (next to the binary, where MLX looks for it) so codesign treats it as
# a nested code object — it must be signed before the main executable and bundle, or bundle signing
# fails with "code object is not signed at all".
#
# Local dev signs WITHOUT --entitlements on purpose: a self-signed teamless cert can't authorize a
# restricted entitlement like keychain-access-groups (AMFI SIGKILLs the app at launch). M7
# notarization (Developer ID cert) adds `--options runtime --entitlements KeyScribe.entitlements`:
#   codesign --force --options runtime --entitlements KeyScribe.entitlements --sign "$ID" ...
[ -f "$APP/Contents/MacOS/mlx.metallib" ] && codesign --force --sign "$ID" "$APP/Contents/MacOS/mlx.metallib"
codesign --force --sign "$ID" "$APP/Contents/MacOS/KeyScribe"
codesign --force --sign "$ID" "$APP"

echo
echo "Done: $APP  (signed: ${ID/#-/ad-hoc})"
echo "Run:  open ./$APP"
echo "Logs: log stream --predicate 'process == \"KeyScribe\"' --level debug"
