#!/usr/bin/env bash
# Refresh appcast.xml for Sparkle from the built, notarized KeyScribe-<version>.dmg. Runs sign_update
# (EdDSA signature, private key read from the login keychain) and upserts one <item> for this version
# into the tracked appcast.xml, newest first; a prerelease's item goes to the beta channel. Pass a version
# to sign that release from another checkout (publish.sh does, to write the feed on main). The feed is served from
# https://raw.githubusercontent.com/rsperko/keyscribe/main/appcast.xml (see SparkleUpdater), so after
# running this, commit appcast.xml to main (publish.sh does this). Run after ./release.sh built the DMG.
#
# Idempotent: Ed25519 signatures are deterministic, so re-running for the same DMG produces no diff.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_UPDATE=".build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST="appcast.xml"
REPO_URL="https://github.com/rsperko/keyscribe"
MIN_OS="15.0"

VERSION="${1:-$(python3 scripts/release_tools.py current | sed 's/^v//')}"
[ -n "$VERSION" ] || { echo "error: no git tag — cut a release first (./release.sh)." >&2; exit 1; }
TAG="v$VERSION"
DMG="KeyScribe-$VERSION.dmg"
[ -f "$DMG" ] || { echo "error: $DMG not found — run ./release.sh first." >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "error: $SIGN_UPDATE missing — run ./release.sh first (its Xcode build downloads Sparkle's tools)." >&2; exit 1; }

# CFBundleVersion scripts/prepare-xcode-project.sh stamps is the commit count; compute it at the tag so it matches the DMG.
BUILD="$(git rev-list --count "$TAG" 2>/dev/null || git rev-list --count HEAD)"
ENCLOSURE_URL="$REPO_URL/releases/download/$TAG/$DMG"

# sign_update prints the enclosure attributes: sparkle:edSignature="…" length="…"
SIG_ATTRS="$("$SIGN_UPDATE" "$DMG")"
[ -n "$SIG_ATTRS" ] || { echo "error: sign_update produced no signature." >&2; exit 1; }

python3 scripts/release_tools.py appcast "$APPCAST" "$VERSION" "$BUILD" "$MIN_OS" "$ENCLOSURE_URL" "$SIG_ATTRS"

echo "appcast: upserted $VERSION (build $BUILD) → $APPCAST"
echo "  enclosure: $ENCLOSURE_URL"
