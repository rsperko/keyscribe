#!/usr/bin/env bash
# Build KeyScribe into a signed .app (LSUIElement menu-bar app) through the shared Xcode app definition
# (App/project.yml), so TCC permissions (Microphone / Accessibility) attach to a stable signed identity
# and survive rebuilds. Full from-source build / signing guide: BUILD.md.
#
# Build variant (KEYSCRIBE_VARIANT): `dev` (default) builds KeyScribeDev.app / com.keyscribe.app.dev —
# fully isolated from an installed production KeyScribe (its own TCC grants, config dir, and Keychain
# service; downloaded models are shared) and signed with the self-signed "KeyScribe Local" cert when
# present, else ad-hoc. `release` builds the production KeyScribe.app / com.keyscribe.app target, signed
# with KEYSCRIBE_SIGN_ID when set, else ad-hoc; release.sh is the notarizing path and archives the same
# target itself. A downstream distribution adds its own target to the shared template instead.
set -euo pipefail
cd "$(dirname "$0")"

VARIANT="${KEYSCRIBE_VARIANT:-dev}"
case "$VARIANT" in
  release|prod|production) SCHEME="KeyScribe";    APP="KeyScribe.app" ;;
  dev)                     SCHEME="KeyScribeDev"; APP="KeyScribeDev.app" ;;
  *) echo "error: KEYSCRIBE_VARIANT must be dev or release (got '$VARIANT')." >&2; exit 1 ;;
esac
DERIVED=".build/xcode"
PRODUCTS="$DERIVED/Build/Products/Release"

PREPARED="$(./scripts/prepare-xcode-project.sh)"
VERSION_SETTINGS=()
while IFS= read -r line; do VERSION_SETTINGS+=("$line"); done <<< "$PREPARED"

# Signing overrides, through the target-scoped KEYSCRIBE_* settings in App/project.yml (a bare
# CODE_SIGN_IDENTITY on the command line would also hit the packages' automatically signed resource
# bundles, which refuse it). The dev target's "KeyScribe Local" cert is machine-local, so fall back to
# ad-hoc when it is absent rather than fail. KEYSCRIBE_SIGN_ID / CODESIGN_IDENTITY are release identities
# and deliberately never touch the dev build.
SIGN_SETTINGS=()
case "$VARIANT" in
  dev)
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "KeyScribe Local"; then
      echo "== signing with: KeyScribe Local =="
    else
      echo "!! AD-HOC signing — no 'KeyScribe Local' cert found. TCC grants (Microphone /" >&2
      echo "!! Accessibility) will NOT survive this rebuild; toggling them on will not stick." >&2
      echo "!! Fix once: ./scripts/setup-dev-signing.sh, then rebuild. See BUILD.md." >&2
      SIGN_SETTINGS=("KEYSCRIBE_DEV_SIGN_IDENTITY=-")
    fi ;;
  *)
    ID="${KEYSCRIBE_SIGN_ID:-${CODESIGN_IDENTITY:-}}"
    if [ -n "$ID" ]; then
      TEAM_ID="$(printf '%s' "$ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
      echo "== signing with: $ID =="
      SIGN_SETTINGS=("KEYSCRIBE_RELEASE_SIGN_IDENTITY=$ID" "KEYSCRIBE_TEAM_ID=$TEAM_ID")
    else
      echo "!! AD-HOC signing the release target (set KEYSCRIBE_SIGN_ID for a Developer ID build)." >&2
      SIGN_SETTINGS=("KEYSCRIBE_RELEASE_SIGN_IDENTITY=-" "KEYSCRIBE_RELEASE_HARDENED_RUNTIME=NO" "KEYSCRIBE_RELEASE_ENTITLEMENTS=")
    fi ;;
esac

echo "== building $SCHEME (Release) =="
xcodebuild build \
  -project App/KeyScribe.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  -disableAutomaticPackageResolution -xcconfig App/Config/Packages.xcconfig \
  "${VERSION_SETTINGS[@]}" "${SIGN_SETTINGS[@]}" \
  -quiet

# Qwen3-ASR runs on MLX, which terminates the app ("Failed to load the default metallib") without its
# shader library. Xcode compiles it into the package's resource bundle; prove MLX finds it from the
# built product before replacing the app.
"$PRODUCTS/$APP/Contents/MacOS/KeyScribe" --mlx-smoke

rm -rf "$APP"
cp -R "$PRODUCTS/$APP" "$APP"
echo
echo "Done: $APP"
echo "Run:  open ./$APP"
echo "Logs: log stream --predicate 'process == \"KeyScribe\"' --level debug"
