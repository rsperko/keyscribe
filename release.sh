#!/usr/bin/env bash
# Build a notarization-ready KeyScribe.app and a stapled KeyScribe-<version>.dmg, signed with a
# Developer ID Application cert + hardened runtime + entitlements. This is the reusable core of the
# release pipeline (used both locally and by .github/workflows/release.yml). For the dev build that
# uses a self-signed cert and skips hardened runtime, use make-app.sh instead.
# Full plan: agent_notes/distribution_plan/README.md.
#
# Usage:
#   ./release.sh                 build/notarize the CURRENT latest tag (re-run a release)
#   ./release.sh patch|minor|major   bump from the latest tag, create the new tag, then build/notarize
#   ./release.sh vX.Y.Z          create that exact tag, then build/notarize
# It stops before anything public: it does NOT push the tag, cut the GitHub release, or bump the
# Homebrew cask — it prints those commands for you to run. Bumping requires a clean working tree
# (a release must be built from committed code).
#
# Required:
#   create-dmg          packaging tool — `brew install create-dmg` (icon + drag-to-Applications DMG).
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
cleanup() { [ -n "$CLEANUP_P8" ] && rm -f "$CLEANUP_P8"; return 0; }
trap cleanup EXIT

if [ -z "$ID" ] || [ "$ID" = "-" ]; then
  echo "error: set KEYSCRIBE_SIGN_ID to a 'Developer ID Application: …' identity." >&2
  echo "       A release cannot be ad-hoc signed. List installed identities with:" >&2
  echo "         security find-identity -v -p codesigning" >&2
  exit 1
fi

# Preflight create-dmg here (not at the DMG step) so a missing tool fails in seconds instead of after
# the multi-minute build + notarization. It is required, not optional: the release DMG's icon and
# drag-to-Applications layout come from create-dmg, and silently shipping a plain hdiutil image would
# be a quality downgrade you would not notice until after publishing.
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg is required for the release DMG — install it once: brew install create-dmg" >&2
  exit 1
fi

# Optional first arg bumps (or sets) the version and creates the tag before building. A bump requires
# a clean tree so the tag — and the version stamped into the DMG — reflect committed code, not
# uncommitted edits. The tag is created locally only; pushing it is one of the printed publish steps.
BUMP="${1:-}"
if [ -n "$BUMP" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty — commit (or stash) before cutting a release, so the tag" >&2
    echo "       points at the exact code you ship. 'git status' to see what's pending." >&2
    exit 1
  fi
  LATEST="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  case "$BUMP" in
    v[0-9]*.[0-9]*.[0-9]*)            # explicit version — works with or without a prior tag
      NEW_TAG="$BUMP" ;;
    major|minor|patch)                # relative bump needs a baseline to bump FROM
      if [ -z "$LATEST" ]; then
        echo "error: no existing tag to bump from — patch/minor/major needs a baseline." >&2
        echo "       for the first release, pass an explicit version: ./release.sh v0.1.0" >&2
        exit 1
      fi
      IFS=. read -r MAJ MIN PAT <<<"$LATEST"
      case "$BUMP" in
        major) NEW_TAG="v$((MAJ+1)).0.0" ;;
        minor) NEW_TAG="v${MAJ}.$((MIN+1)).0" ;;
        patch) NEW_TAG="v${MAJ}.${MIN}.$((PAT+1))" ;;
      esac ;;
    *) echo "error: first arg must be patch | minor | major | vX.Y.Z (got '$BUMP')." >&2; exit 1 ;;
  esac
  if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
    echo "error: tag $NEW_TAG already exists." >&2; exit 1
  fi
  echo "== tagging $NEW_TAG${LATEST:+ (was v$LATEST)} =="
  git tag "$NEW_TAG"
fi

# Version comes from the latest git tag (make-app.sh stamps it into Info.plist). A release must be
# tagged so the DMG name and the in-app version agree — refuse to build an untagged release.
SHORT_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$SHORT_VERSION" ]; then
  echo "error: no git tag found — pass a bump (./release.sh patch) or tag first (git tag v0.1.0)." >&2
  exit 1
fi
TAG="v$SHORT_VERSION"
DMG="KeyScribe-$SHORT_VERSION.dmg"

# Whatever path got us here (bump or re-run), the packaged bits must match $TAG exactly. make-app.sh
# stamps the in-app version from `git describe --tags --dirty`, so a dirty tree or a HEAD past the tag
# would ship a "$DMG" named for the clean tag but containing uncommitted/post-tag code. Refuse both.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — a release must be built from committed code matching $TAG." >&2
  echo "       commit or stash, then re-run. 'git status' shows what is pending." >&2
  exit 1
fi
if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "error: HEAD is not at $TAG — would package code that does not match the tag name." >&2
  echo "       checkout the tag ('git checkout $TAG') or cut a new one ('./release.sh patch')." >&2
  exit 1
fi

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
KEYSCRIBE_VARIANT=release KEYSCRIBE_SIGN_ID="$ID" ./make-app.sh release

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
# create-dmg (preflighted at the top) occasionally exits non-zero on success (its AppleScript layout
# step), so verify the output exists rather than trusting the exit code. --volicon gives the volume
# the app icon.
create-dmg --volname "KeyScribe" --volicon "Resources/AppIcon.icns" \
  --app-drop-link 450 150 --icon "$APP" 150 150 "$DMG" "$APP" || true
[ -f "$DMG" ] || { echo "error: create-dmg failed to produce $DMG" >&2; exit 1; }

if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
  echo "== notarize + staple dmg =="
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"

  # Self-verify the artifact before handing it off: the DMG's ticket validates, and the app *inside*
  # is accepted by Gatekeeper as Notarized Developer ID and is itself stapled. Always detach the mount
  # (even on failure) so a verify never leaves a stray /Volumes entry. Fail loudly — a bad DMG must not
  # reach the publish step.
  echo "== verify stapled dmg =="
  xcrun stapler validate "$DMG"
  ATTACH="$(hdiutil attach "$DMG" -nobrowse -readonly)"
  DEV="$(printf '%s\n' "$ATTACH" | grep -oE '^/dev/disk[0-9]+' | head -1)"
  MP="$(printf '%s\n' "$ATTACH" | grep -o '/Volumes/.*' | tail -1)"
  if spctl -a -t exec -vv "$MP/$APP" 2>&1 | grep -q "source=Notarized Developer ID" \
     && xcrun stapler validate "$MP/$APP" >/dev/null 2>&1; then VERIFY_OK=1; else VERIFY_OK=0; fi
  # Detach by device with -force: the volume is briefly busy right after spctl/stapler read it, so a
  # plain detach-by-path silently fails under `|| true` and strands the mount. Force, then retry once.
  hdiutil detach "$DEV" -force >/dev/null 2>&1 || { sleep 1; hdiutil detach "$DEV" -force >/dev/null 2>&1; } || true
  [ "$VERIFY_OK" = 1 ] || { echo "error: $DMG failed Gatekeeper/staple verification — do NOT publish it." >&2; exit 1; }
  echo "verified: app inside is accepted as Notarized Developer ID, and stapled."
else
  echo "note: notarization skipped (set NOTARY_PROFILE or NOTARY_KEY_P8/_ID/ISSUER_ID). Notarize manually:" >&2
  echo "  xcrun notarytool submit $DMG --keychain-profile keyscribe-notary --wait && xcrun stapler staple $DMG" >&2
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
# 0.x releases are flagged prerelease so Homebrew's github_latest livecheck skips them.
PRERELEASE=""; [ "${SHORT_VERSION%%.*}" = "0" ] && PRERELEASE=" --prerelease"
echo
echo "Done: $DMG"
echo "sha256: $SHA"
echo
echo "Publish (stops before anything public — run when ready):"
echo "  make publish    # push tag + GitHub release (auto-notes) + cask + tap, for $TAG"
