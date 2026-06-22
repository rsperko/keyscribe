#!/usr/bin/env bash
# Build KeyScribe into a signed KeyScribe.app (LSUIElement menu-bar app) so TCC permissions
# (Microphone / Input Monitoring / Accessibility) attach to a stable signed identity and
# survive rebuilds. Signs with "SnagShot Dev" if present, else ad-hoc (TCC may reset).
set -euo pipefail
cd "$(dirname "$0")"

APP="KeyScribe.app"
BIN=".build/release/KeyScribe"
BUNDLE_ID="com.keyscribe.app"
CONFIG="${1:-release}"

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
# MLX loads mlx.metallib from next to the executable — place it in MacOS/, beside the binary.
METALLIB=".build/$CONFIG/mlx.metallib"
if [ -f "$METALLIB" ]; then
  cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"
else
  echo "warning: $METALLIB missing — Qwen3-ASR will crash at runtime" >&2
fi
# Bundled model self-test clip (loaded via Bundle.main at runtime).
cp Resources/model-selftest.wav "$APP/Contents/Resources/model-selftest.wav"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>KeyScribe</string>
  <key>CFBundleExecutable</key><string>KeyScribe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>KeyScribe transcribes your speech on this Mac. Audio is never sent to the cloud or stored.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>KeyScribe reads the active browser tab's URL only when you use a mode that routes by website. The URL never leaves this Mac.</string>
</dict>
</plist>
PLIST

# Stable-identity signing keeps TCC grants across rebuilds. Pass KEYSCRIBE_SIGN_ID to choose a
# cert (e.g. "SnagShot Dev" or a "Developer ID Application: …" name); signing with a real cert
# prompts once for keychain access — run this from your terminal and click "Always Allow".
# Identity: KEYSCRIBE_SIGN_ID if set, else auto-detect a "SnagShot Dev" cert in the keychain (stable
# TCC across rebuilds), else fall back to ad-hoc (TCC may reset each rebuild). Sign inner Mach-O
# then the bundle (no --deep: Swift linker-signs the binary and --deep mishandles it).
ID="${KEYSCRIBE_SIGN_ID:-}"
if [ -z "$ID" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "SnagShot Dev"; then
    ID="SnagShot Dev"
  else
    ID="-"
  fi
fi
find "$APP" -name "*.cstemp" -delete 2>/dev/null || true
if [ "$ID" = "-" ]; then
  echo "== AD-HOC signing (no SnagShot Dev cert found; TCC may reset) =="
else
  echo "== signing with: $ID =="
fi
# mlx.metallib sits in MacOS/ (next to the binary, where MLX looks for it) so codesign treats it as
# a nested code object — it must be signed before the main executable and bundle, or bundle signing
# fails with "code object is not signed at all".
[ -f "$APP/Contents/MacOS/mlx.metallib" ] && codesign --force --sign "$ID" "$APP/Contents/MacOS/mlx.metallib"
codesign --force --sign "$ID" "$APP/Contents/MacOS/KeyScribe"
codesign --force --sign "$ID" "$APP"

echo
echo "Done: $APP"
echo "Run:  open ./$APP"
echo "Logs: log stream --predicate 'process == \"KeyScribe\"' --level debug"
