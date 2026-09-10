#!/usr/bin/env bash
# Build KeyScribe into a signed KeyScribe.app (LSUIElement menu-bar app) so TCC permissions
# (Microphone / Accessibility) attach to a stable signed identity and
# survive rebuilds. Signs with a stable cert if one is found, else ad-hoc (TCC may reset).
# A failed build never replaces the app: it is staged, signed, and validated first. Guide: BUILD.md.
set -euo pipefail
cd "$(dirname "$0")"

# Build variant (KEYSCRIBE_VARIANT): `dev` (default) builds KeyScribeDev.app / com.keyscribe.app.dev —
# fully isolated from an installed production KeyScribe (its own TCC grants, config dir, and Keychain
# service; downloaded models are shared). `release` (set by release.sh) builds the production
# KeyScribe.app / com.keyscribe.app. `custom` builds a generic isolated variant whose app name,
# bundle id, and bundle name come from KEYSCRIBE_APP_NAME / KEYSCRIBE_BUNDLE_ID / KEYSCRIBE_BUNDLE_NAME
# (no identity hardcoded here) — it gets its own config dir / Keychain / display name the same way dev
# does, and shares the downloaded models. The executable inside is named "KeyScribe" for every variant.
VARIANT="${KEYSCRIBE_VARIANT:-dev}"
case "$VARIANT" in
  release|prod|production) APP="KeyScribe.app";    BUNDLE_ID="com.keyscribe.app";     BUNDLE_NAME="KeyScribe" ;;
  custom)                  APP="${KEYSCRIBE_APP_NAME:?custom variant requires KEYSCRIBE_APP_NAME}.app"
                           BUNDLE_ID="${KEYSCRIBE_BUNDLE_ID:?custom variant requires KEYSCRIBE_BUNDLE_ID}"
                           BUNDLE_NAME="${KEYSCRIBE_BUNDLE_NAME:?custom variant requires KEYSCRIBE_BUNDLE_NAME}" ;;
  dev|*)                   APP="KeyScribeDev.app"; BUNDLE_ID="com.keyscribe.app.dev"; BUNDLE_NAME="KeyScribeDev" ;;
esac
BIN=".build/release/KeyScribe"
CONFIG="${1:-release}"

# A leftover backup may be the only working app: refuse to build, and never delete it.
for leftover in .build/make-app.*/backup; do
  [ -e "$leftover" ] || continue
  echo "!! A previous make-app.sh run left a backup of an app at: $leftover" >&2
  echo "!! Move the app you want to keep into place, delete that directory, then rebuild." >&2
  exit 1
done

# Preflight: catch the failure modes a fresh clone hits — wrong arch, missing or Command-Line-Tools-
# only Xcode, a toolchain that cannot compile SwiftUI, absent Metal Toolchain — up front with an
# actionable message, instead of a cryptic error minutes into the build. All of them are fatal, for
# every variant. Full guide: BUILD.md.
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
# The Command Line Tools carry no Metal compiler and no SwiftUI macro plugins (no
# libSwiftUIMacros.dylib / libPreviewsMacros.dylib — those ship under Xcode's
# Platforms/MacOSX.platform). Against a recent SDK that is fatal: a SwiftUI file fails with
# "plugin for module 'SwiftUIMacros' not found" (reported on the macOS 27 CLT SDK), and any Metal
# compile fails with "unable to spawn process 'metal'". Fail here rather than minutes into the build.
case "$DEVDIR" in
  *CommandLineTools*)
    echo "!! xcode-select points at the Command Line Tools ($DEVDIR), not full Xcode." >&2
    echo "!! The CLT ship no Metal compiler and no SwiftUI macro plugins, so this build fails" >&2
    echo "!! partway through ('unable to spawn process metal' / 'plugin for module SwiftUIMacros" >&2
    echo "!! not found'). Fix: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
    ;;
esac
# xcode-select is not what the compiler uses. SDKROOT (which SwiftPM honors ahead of xcrun), a
# DEVELOPER_DIR at another Xcode, or an unaccepted license all change or break the SDK the build
# resolves while xcode-select still points at Xcode. So typecheck the capability a Command Line Tools
# SDK lacks — a SwiftUI macro, whose plugin is located through the resolved SDK — with the same
# swiftc and environment `swift build` inherits. ~1 s; a CLT SDK fails it with the exact
# "plugin for module 'SwiftUIMacros' not found" the build would hit minutes in.
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
PROBE_DIR="$(mktemp -d)"
printf 'import SwiftUI\nextension EnvironmentValues { @Entry var toolchainProbe = 0 }\n' > "$PROBE_DIR/probe.swift"
if ! swiftc -typecheck "$PROBE_DIR/probe.swift" >"$PROBE_DIR/out.txt" 2>&1; then
  echo "!! This toolchain cannot compile SwiftUI, so the build would fail partway through." >&2
  echo "!! SDK: ${SDK_PATH:-unresolved}" >&2
  { grep -m1 -E 'error:|license' "$PROBE_DIR/out.txt" || head -3 "$PROBE_DIR/out.txt"; } | sed 's/^/!!   /' >&2
  if [ -n "${SDKROOT:-}" ]; then
    echo "!! SDKROOT is set and overrides xcode-select. Fix: unset SDKROOT" >&2
  elif [ -n "${DEVELOPER_DIR:-}" ]; then
    echo "!! DEVELOPER_DIR is set and overrides xcode-select. Fix: unset DEVELOPER_DIR" >&2
  else
    echo "!! Fix: sudo xcode-select -s /Applications/Xcode.app (and sudo xcodebuild -license accept if asked)" >&2
  fi
  rm -rf "$PROBE_DIR"
  exit 1
fi
rm -rf "$PROBE_DIR"
# `xcrun -f metal` finds Xcode's stub even without the toolchain, so compile and link a real kernel.
./scripts/build-mlx-metallib.sh --probe >/dev/null
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
# The exact commit the build came from (generic build metadata — lets a build later tell whether it
# is behind the repo's main). Falls back like the versions above when built from a non-git tarball.
SCM_REVISION="$(git rev-parse HEAD 2>/dev/null || true)"
[ -z "$SCM_REVISION" ] && SCM_REVISION="unknown"

# Build system is pinned, not left to the toolchain default: Swift 6.4 flips SwiftPM's default to
# `swiftbuild`, which relocates products out of .build/<config> (breaking the copy below) and pulls
# MLX's .metal sources into `swift build` (displacing the curated metallib built after this). Full
# rationale + the migration this defers: scripts/swiftpm-build-system.sh. Deliberately unquoted —
# the helper prints either nothing or the two flag tokens.
BUILD_SYSTEM="$(./scripts/swiftpm-build-system.sh)"
echo "== building KeyScribe ($CONFIG) ${BUILD_SYSTEM:+[$BUILD_SYSTEM]} =="
# shellcheck disable=SC2086
swift build -c "$CONFIG" $BUILD_SYSTEM --product KeyScribe
[ "$CONFIG" = "debug" ] && BIN=".build/debug/KeyScribe"

# Qwen3-ASR needs this library and the native build system compiles no Metal shaders (see the pin above).
# Fatal: an app without it offers models that cannot run.
echo "== building mlx.metallib (required by Qwen3-ASR) =="
BUILD_DIR="$(pwd)/.build" ./scripts/build-mlx-metallib.sh "$CONFIG"
METALLIB=".build/$CONFIG/mlx.metallib"
[ -f "$METALLIB" ] || { echo "!! $METALLIB is missing after the shader build" >&2; exit 1; }

# Same filesystem as the app (the swap is two renames) and fresh, so neither rename nests; cleanup
# restores an interrupted swap.
mkdir -p .build
WORK="$(mktemp -d .build/make-app.XXXXXX)"
STAGE="$WORK/stage/$APP"
SWAPPED=0
cleanup() {
  if [ "$SWAPPED" = 0 ] && [ -e "$WORK/backup/$APP" ]; then
    if [ ! -e "$APP" ] && mv "$WORK/backup/$APP" "$APP"; then
      echo "!! interrupted while replacing the app — restored the previous $APP" >&2
    else
      echo "!! could not restore the previous app — it is kept at $WORK/backup/$APP" >&2
      return
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo "== assembling $APP (staged) =="
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/KeyScribe"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
mkdir -p "$STAGE/Contents/Resources/Legal"
cp LICENSE "$STAGE/Contents/Resources/Legal/LICENSE"
cp THIRD-PARTY-NOTICES.md "$STAGE/Contents/Resources/Legal/THIRD-PARTY-NOTICES.md"
DEPENDENCY_LEGAL="$STAGE/Contents/Resources/Legal/Dependencies"
mkdir -p "$DEPENDENCY_LEGAL"
for dependency in .build/checkouts/*; do
  [ -d "$dependency" ] || continue
  dependency_name="$(basename "$dependency")"
  if [ "$dependency_name" = "Sparkle" ] && ! otool -L "$STAGE/Contents/MacOS/KeyScribe" 2>/dev/null | grep -q "Sparkle.framework"; then
    continue
  fi
  for notice in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
    [ -f "$notice" ] || continue
    cp "$notice" "$DEPENDENCY_LEGAL/$dependency_name-$(basename "$notice")"
  done
done
# MLX loads mlx.metallib from next to the executable — place it in MacOS/, beside the binary.
cp "$METALLIB" "$STAGE/Contents/MacOS/mlx.metallib"
# Sparkle.framework is present in the build products ONLY for the public production build
# (KEYSCRIBE_SPARKLE=1 adds Sparkle to the SwiftPM graph). Embed it keyed off that presence, NOT the
# variant, so this is a clean no-op for dev/custom builds and a downstream white-label build that builds
# via `make-app.sh KEYSCRIBE_VARIANT=custom` needs no change here. See agent_notes/distribution_plan/sparkle.md.
SPARKLE_FW=".build/$CONFIG/Sparkle.framework"
# Key off the BINARY actually linking Sparkle, not just the framework being present in .build — a prior
# KEYSCRIBE_SPARKLE=1 build can leave a stale Sparkle.framework in .build that a later flag-off build
# would otherwise embed into an app whose binary does not link it (dead weight, and it fools a presence
# check). The otool linkage test only passes when this build actually linked Sparkle.
if otool -L "$STAGE/Contents/MacOS/KeyScribe" 2>/dev/null | grep -q "Sparkle.framework" && [ -d "$SPARKLE_FW" ]; then
  echo "== embedding Sparkle.framework =="
  mkdir -p "$STAGE/Contents/Frameworks"
  rm -rf "$STAGE/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE_FW" "$STAGE/Contents/Frameworks/Sparkle.framework"
  # The binary loads Sparkle as @rpath/Sparkle.framework/..., but SwiftPM only emits @loader_path
  # (= Contents/MacOS) rpaths for an executable target — it never adds the app-bundle Frameworks rpath,
  # so without this dyld cannot find the embedded framework and the app crashes at launch. Add it before
  # signing (install_name_tool invalidates the signature; we sign below). Fresh binary copy each build,
  # so no duplicate rpath accumulates.
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$STAGE/Contents/MacOS/KeyScribe"
fi
# Bundled model self-test clip (loaded via Bundle.main at runtime).
cp Resources/model-selftest.wav "$STAGE/Contents/Resources/model-selftest.wav"
# First-party "now listening" start cue (loaded via Bundle.main at runtime).
cp Resources/start-cue.wav "$STAGE/Contents/Resources/start-cue.wav"
# Info.plist is a tracked source file (Resources/Info.plist); stamp the git-derived version into it.
echo "== Info.plist: $BUNDLE_NAME $SHORT_VERSION (build $BUILD_VERSION), id $BUNDLE_ID, scm $SCM_REVISION =="
sed -e "s/__SHORT_VERSION__/$SHORT_VERSION/" -e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__BUNDLE_NAME__/$BUNDLE_NAME/" \
    -e "s/__SCM_REVISION__/$SCM_REVISION/" \
  Resources/Info.plist > "$STAGE/Contents/Info.plist"

# Signing identity is variant-aware (macOS TCC only needs a *valid, stable* signature — no Apple
# account required for dev). Sign inner Mach-O then the bundle (no --deep: the Swift linker-signs the
# binary and --deep mishandles it). A real cert prompts once for keychain access — click "Always Allow".
#
#  - dev: a stable *self-signed* cert ("KeyScribe Local") so the dev app's TCC grants persist across
#    rebuilds, separate from production. KEYSCRIBE_SIGN_ID / CODESIGN_IDENTITY are *release* identities
#    and are deliberately ignored here — an .envrc that exports KEYSCRIBE_SIGN_ID for release.sh must
#    not Developer-ID-sign the dev build. Falls back to ad-hoc if the cert is not found.
#  - release: the Developer ID identity from KEYSCRIBE_SIGN_ID, then CODESIGN_IDENTITY (release.sh sets
#    it); else ad-hoc. release.sh additionally adds --options runtime + --entitlements and notarizes.
case "$VARIANT" in
  release|prod|production|custom)
    # release uses the Developer ID from release.sh; custom signs with whatever identity the build
    # provides (KEYSCRIBE_SIGN_ID, else CODESIGN_IDENTITY), else ad-hoc.
    ID="${KEYSCRIBE_SIGN_ID:-${CODESIGN_IDENTITY:-}}"
    ;;
  *)
    ID=""
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "KeyScribe Local"; then
      ID="KeyScribe Local"
    fi
    ;;
esac
[ -z "$ID" ] && ID="-"
find "$STAGE" -name "*.cstemp" -delete 2>/dev/null || true
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
# Sparkle embeds nested code (XPC services, Autoupdate, Updater.app) inside its framework; sign
# inside-out (deepest first) then the framework, before the metallib/binary/bundle — a nested code
# object left unsigned fails bundle signing with "code object is not signed at all". Paths go through
# Versions/Current so they are version-letter agnostic. Dev signs plain like the rest of the bundle;
# release.sh layers the hardened-runtime + per-XPC-entitlements re-sign on top for notarization.
EMBEDDED_FW="$STAGE/Contents/Frameworks/Sparkle.framework"
if [ -d "$EMBEDDED_FW" ]; then
  echo "== signing Sparkle.framework (inside-out) =="
  FWV="$EMBEDDED_FW/Versions/Current"
  codesign --force --sign "$ID" "$FWV/XPCServices/Downloader.xpc"
  codesign --force --sign "$ID" "$FWV/XPCServices/Installer.xpc"
  codesign --force --sign "$ID" "$FWV/Updater.app"
  codesign --force --sign "$ID" "$FWV/Autoupdate"
  codesign --force --sign "$ID" "$EMBEDDED_FW"
fi
codesign --force --sign "$ID" "$STAGE/Contents/MacOS/mlx.metallib"
codesign --force --sign "$ID" "$STAGE/Contents/MacOS/KeyScribe"
codesign --force --sign "$ID" "$STAGE"

echo "== validating $APP (staged) =="
if ! ./scripts/validate-qwen-runtime.sh "$STAGE/Contents/MacOS/KeyScribe"; then
  echo "!! The staged app failed validation, so $APP was left untouched." >&2
  exit 1
fi

echo "== replacing $APP =="
if [ -e "$APP" ]; then
  mkdir -p "$WORK/backup"
  mv "$APP" "$WORK/backup/$APP"
fi
mv "$STAGE" "$APP"
SWAPPED=1

echo
echo "Done: $APP  (signed: ${ID/#-/ad-hoc})"
echo "Run:  open ./$APP"
echo "Logs: log stream --predicate 'process == \"KeyScribe\"' --level debug"
