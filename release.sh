#!/usr/bin/env bash
# Build a notarization-ready KeyScribe.app and a stapled KeyScribe-<version>.dmg, signed with a
# Developer ID Application cert + hardened runtime + entitlements. This is the reusable core of the
# release pipeline (used both locally and by .github/workflows/release.yml). For the dev build that
# uses a self-signed cert and skips hardened runtime, use make-app.sh instead.
# Full plan: agent_notes/distribution_plan/README.md.
#
# Required:
#   KEYSCRIBE_SIGN_ID   "Developer ID Application: Your Name (TEAMID)" — NOT ad-hoc; a release must
#                       carry a real Developer ID signature or notarization rejects it.
#
# Notarization (skipped if no auth is provided — the DMG is still built, just unstapled):
#   NOTARY_PROFILE      a `notarytool store-credentials` keychain profile name (local convenience), OR
#   NOTARY_KEY_P8 / NOTARY_KEY_ID / NOTARY_ISSUER_ID
#                       App Store Connect API key (NOTARY_KEY_P8 is the base64 of the .p8) — for CI.
set -euo pipefail
cd "$(dirname "$0")"

APP="KeyScribe.app"
ENT="KeyScribe.entitlements"
ID="${KEYSCRIBE_SIGN_ID:-}"

CLEANUP_P8=""
cleanup() { [ -n "$CLEANUP_P8" ] && rm -f "$CLEANUP_P8"; }
trap cleanup EXIT

if [ -z "$ID" ] || [ "$ID" = "-" ]; then
  echo "error: set KEYSCRIBE_SIGN_ID to a 'Developer ID Application: …' identity." >&2
  echo "       A release cannot be ad-hoc signed. List installed identities with:" >&2
  echo "         security find-identity -v -p codesigning" >&2
  exit 1
fi

# Version comes from the latest git tag (make-app.sh stamps it into Info.plist). A release must be
# tagged so the DMG name and the in-app version agree — refuse to build an untagged release.
SHORT_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$SHORT_VERSION" ]; then
  echo "error: no git tag found — tag the release first, e.g. 'git tag v1.0.0'." >&2
  exit 1
fi
DMG="KeyScribe-$SHORT_VERSION.dmg"

# Pick notary auth from the environment; empty array ⇒ notarization is skipped.
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_P8:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  CLEANUP_P8="$(mktemp /tmp/keyscribe-notary.XXXXXX.p8)"
  printf '%s' "$NOTARY_KEY_P8" | base64 -d > "$CLEANUP_P8"
  NOTARY_ARGS=(--key "$CLEANUP_P8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

echo "== build + assemble (KeyScribe $SHORT_VERSION) =="
KEYSCRIBE_SIGN_ID="$ID" ./make-app.sh release

# Re-sign for distribution: hardened runtime (--options runtime), secure timestamp, and the
# entitlements make-app.sh's dev signing omits. Nested object first (the metallib is a nested code
# object beside the binary), then the binary, then the bundle. No --deep (the Swift linker pre-signs
# the binary and --deep mishandles it).
echo "== re-sign for distribution =="
codesign --force --options runtime --timestamp \
  --sign "$ID" "$APP/Contents/MacOS/mlx.metallib"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$ID" "$APP/Contents/MacOS/KeyScribe"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
  echo "== notarize + staple app =="
  ZIP="$(mktemp -d)/KeyScribe.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"          # notarytool wants a zip/dmg; stapler staples the .app
  xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
fi

echo "== build dmg: $DMG =="
rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
  # create-dmg occasionally exits non-zero on success (AppleScript layout step) — verify the output
  # exists rather than trusting the exit code.
  create-dmg --volname "KeyScribe" --app-drop-link 450 150 --icon "$APP" 150 150 "$DMG" "$APP" || true
else
  echo "note: create-dmg not found (brew install create-dmg) — using hdiutil (no drag-to-Applications layout)." >&2
  hdiutil create -volname "KeyScribe" -srcfolder "$APP" -ov -format UDZO "$DMG"
fi
[ -f "$DMG" ] || { echo "error: failed to produce $DMG" >&2; exit 1; }

if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
  echo "== notarize + staple dmg =="
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
else
  echo "note: notarization skipped (set NOTARY_PROFILE or NOTARY_KEY_P8/_ID/ISSUER_ID). Notarize manually:" >&2
  echo "  xcrun notarytool submit $DMG --keychain-profile keyscribe-notary --wait && xcrun stapler staple $DMG" >&2
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo
echo "Done: $DMG"
echo "sha256: $SHA"
echo "  → paste into Casks/keyscribe.rb (sha256) and bump version to $SHORT_VERSION"
