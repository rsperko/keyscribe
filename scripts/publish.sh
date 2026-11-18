#!/usr/bin/env bash
# Publish an already-built, self-verified release: push the tag, create the GitHub release (with the
# DMG, the voice kit, and auto-generated notes), refresh the cask in the tap, and commit + push the tap. This is the
# outward-facing tail — run it deliberately, after ./release.sh has built + verified
# KeyScribe-<version>.dmg. Re-runnable (re-uploads the asset, skips an unchanged cask).
#
#   KEYSCRIBE_TAP_DIR   homebrew-tap checkout (default ../homebrew-tap).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 scripts/release_tools.py current | sed 's/^v//')"
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

BETA=0; case "$VERSION" in *-*) BETA=1 ;; esac
PRERELEASE=""; { [ "${VERSION%%.*}" = "0" ] || [ "$BETA" = 1 ]; } && PRERELEASE="--prerelease"

# Writing the feed from a release branch pushes local main, so anything unpushed there would ship with it.
# Checked before anything goes public.
BRANCH="$(git symbolic-ref --short -q HEAD || true)"
if [ "$BRANCH" != "main" ]; then
  git fetch origin main
  if [ "$(git rev-list --count origin/main..main)" != "0" ]; then
    echo "error: local main has commits origin/main does not; push or drop them before publishing from ${BRANCH:-a detached HEAD}." >&2
    exit 1
  fi
fi

# The voice kit rides each release so a recipient can fetch it beside the DMG it was tested with.
KIT_ZIP="KeyScribe-voice-kit-$VERSION.zip"
KIT_BUILD="$(mktemp -d)"
zsh voice-kit/package.sh --out "$KIT_BUILD"
mv "$KIT_BUILD/voice-kit.zip" "$KIT_ZIP"
rm -rf "$KIT_BUILD"

echo "== push tag $TAG =="
git push origin "$TAG"

echo "== GitHub release $TAG =="
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "  release exists — replacing the DMG and voice kit assets"
  gh release upload "$TAG" "$DMG" "$KIT_ZIP" -R "$REPO" --clobber
else
  # A release's notes start at the release before it, so they cover its betas' changes too.
  NOTES_START="$(python3 scripts/release_tools.py notes-start "$TAG")"
  gh release create "$TAG" "$DMG" "$KIT_ZIP" -R "$REPO" $PRERELEASE \
    --title "KeyScribe $VERSION" --generate-notes ${NOTES_START:+--notes-start-tag "$NOTES_START"}
fi

# The cask tracks releases only; beta users get betas through the in-app update channel.
if [ "$BETA" = 1 ]; then
  echo "== cask: skipped for a beta =="
else
  echo "== refresh + push cask =="
  ./scripts/update-cask.sh
  git -C "$TAP_DIR" add Casks/keyscribe.rb
  if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "  cask unchanged — nothing to push"
  else
    git -C "$TAP_DIR" commit -m "keyscribe $VERSION"
    git -C "$TAP_DIR" push
  fi
fi

# Refresh the Sparkle appcast (EdDSA-sign the DMG, upsert this version) and commit it to main — the feed
# is served from raw.githubusercontent main/appcast.xml. This lands as a follow-up commit after the
# release tag, which is fine: the DMG-vs-tag gate above already passed, and the enclosure now points at
# the release asset just uploaded. Idempotent, so re-running publish is safe.
# A fix released from a release branch still has to land in main's feed, or no installed copy sees it.
echo "== refresh + push appcast =="
return_to_release() {
  if [ -n "$BRANCH" ]; then git switch "$BRANCH"; else git switch --detach "$TAG"; fi \
    || echo "warning: still on main; switch back with: git switch ${BRANCH:---detach $TAG}" >&2
}
if [ "$BRANCH" != "main" ]; then
  echo "  releasing from ${BRANCH:-a detached HEAD}; writing the feed on main"
  git switch main
  trap return_to_release EXIT
  git pull --ff-only origin main
fi
./scripts/appcast.sh "$VERSION"
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
[ "$BETA" = 1 ] && echo "Beta: reaches people with Get beta updates turned on." || echo "Install:  brew install rsperko/tap/keyscribe"
