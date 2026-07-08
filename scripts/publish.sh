#!/usr/bin/env bash
# Publish an already-built, self-verified release: push the tag, create the GitHub release (with the
# DMG and auto-generated notes), refresh the cask in the tap, and commit + push the tap. This is the
# outward-facing tail — run it deliberately, after ./release.sh has built + verified
# KeyScribe-<version>.dmg. Re-runnable (re-uploads the asset, skips an unchanged cask).
#
#   KEYSCRIBE_TAP_DIR   homebrew-tap checkout (default ../homebrew-tap).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$VERSION" ] || { echo "error: no git tag — cut a release first (./release.sh patch)." >&2; exit 1; }
TAG="v$VERSION"
DMG="KeyScribe-$VERSION.dmg"
TAP_DIR="${KEYSCRIBE_TAP_DIR:-../homebrew-tap}"
REPO="rsperko/keyscribe"

[ -f "$DMG" ] || { echo "error: $DMG not built — run ./release.sh first." >&2; exit 1; }
[ -d "$TAP_DIR" ] || { echo "error: tap not found at $TAP_DIR (set KEYSCRIBE_TAP_DIR)." >&2; exit 1; }
# Publish exactly what was built: HEAD must be at the tag the DMG was cut from.
if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "error: HEAD is not at $TAG — would publish a tag that does not match your checkout." >&2
  exit 1
fi

# Hard gate: refuse to publish unless the release preflight passed for THIS exact commit. The stamp is
# written by ./scripts/preflight.sh only after the required Tier A+B+C checks are recorded satisfied,
# and is keyed to the commit SHA. Moving HEAD invalidates it; rebuilding the artifact at the same commit
# requires rerunning preflight before publish. Emergency override:
# KEYSCRIBE_SKIP_PREFLIGHT=1 (say so out loud — you are shipping unverified).
STAMP=".preflight-pass"
if [ "${KEYSCRIBE_SKIP_PREFLIGHT:-0}" = "1" ]; then
  echo "warning: KEYSCRIBE_SKIP_PREFLIGHT=1 — publishing WITHOUT a verified preflight." >&2
elif [ ! -f "$STAMP" ] || [ "$(head -1 "$STAMP" 2>/dev/null)" != "$(git rev-parse HEAD)" ]; then
  echo "error: no passing preflight for this commit — run ./scripts/preflight.sh (or 'make preflight') first." >&2
  echo "       the release gate must be green before anything goes public. See docs/development/release_testing.md." >&2
  exit 1
fi

PRERELEASE=""; [ "${VERSION%%.*}" = "0" ] && PRERELEASE="--prerelease"

echo "== push tag $TAG =="
git push origin "$TAG"

echo "== GitHub release $TAG =="
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "  release exists — replacing the DMG asset"
  gh release upload "$TAG" "$DMG" -R "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" -R "$REPO" $PRERELEASE \
    --title "KeyScribe $VERSION" --generate-notes
fi

echo "== refresh + push cask =="
./scripts/update-cask.sh
git -C "$TAP_DIR" add Casks/keyscribe.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "  cask unchanged — nothing to push"
else
  git -C "$TAP_DIR" commit -m "keyscribe $VERSION"
  git -C "$TAP_DIR" push
fi

# Refresh the Sparkle appcast (EdDSA-sign the DMG, upsert this version) and commit it to main — the feed
# is served from raw.githubusercontent main/appcast.xml. This lands as a follow-up commit after the
# release tag, which is fine: the DMG-vs-tag gate above already passed, and the enclosure now points at
# the release asset just uploaded. Idempotent, so re-running publish is safe.
echo "== refresh + push appcast =="
./scripts/appcast.sh
# A malformed appcast breaks the update feed for every installed client — validate before committing.
python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('appcast.xml')" \
  || { echo "error: appcast.xml is not valid XML — refusing to publish a broken feed." >&2; exit 1; }
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" appcast.xml \
  || { echo "error: appcast.xml has no item for $VERSION — appcast.sh did not upsert this release." >&2; exit 1; }
git add appcast.xml
if git diff --cached --quiet; then
  echo "  appcast unchanged — nothing to push"
else
  git commit -m "appcast: KeyScribe $VERSION"
  git push origin HEAD:main
fi

echo
echo "Published $TAG → https://github.com/$REPO/releases/tag/$TAG"
echo "Install:  brew install rsperko/tap/keyscribe"
