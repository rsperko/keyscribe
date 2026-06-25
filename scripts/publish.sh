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

echo
echo "Published $TAG → https://github.com/$REPO/releases/tag/$TAG"
echo "Install:  brew install rsperko/tap/keyscribe"
