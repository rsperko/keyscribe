#!/usr/bin/env bash
# Refresh appcast.xml for Sparkle from the built, notarized KeyScribe-<version>.dmg. Runs sign_update
# (EdDSA signature, private key read from the login keychain) and upserts one <item> for this version
# into the tracked appcast.xml, newest first. The feed is served from
# https://raw.githubusercontent.com/rsperko/keyscribe/main/appcast.xml (see SparkleUpdater), so after
# running this, commit appcast.xml to main (publish.sh does this). Run after ./release.sh built the DMG.
#
# Idempotent: Ed25519 signatures are deterministic, so re-running for the same DMG produces no diff.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST="appcast.xml"
REPO_URL="https://github.com/rsperko/keyscribe"
MIN_OS="15.0"
KEEP=10

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$VERSION" ] || { echo "error: no git tag — cut a release first (./release.sh)." >&2; exit 1; }
TAG="v$VERSION"
DMG="KeyScribe-$VERSION.dmg"
[ -f "$DMG" ] || { echo "error: $DMG not found — run ./release.sh first." >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "error: $SIGN_UPDATE missing — build once with KEYSCRIBE_SPARKLE=1 to fetch Sparkle's tools." >&2; exit 1; }

# CFBundleVersion make-app.sh stamps is the commit count; compute it at the tag so it matches the DMG.
BUILD="$(git rev-list --count "$TAG" 2>/dev/null || git rev-list --count HEAD)"
ENCLOSURE_URL="$REPO_URL/releases/download/$TAG/$DMG"

# sign_update prints the enclosure attributes: sparkle:edSignature="…" length="…"
SIG_ATTRS="$("$SIGN_UPDATE" "$DMG")"
[ -n "$SIG_ATTRS" ] || { echo "error: sign_update produced no signature." >&2; exit 1; }

NEW_ITEM="    <item>
      <title>$VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url=\"$ENCLOSURE_URL\" $SIG_ATTRS type=\"application/octet-stream\" />
    </item>"

APPCAST="$APPCAST" VERSION="$VERSION" NEW_ITEM="$NEW_ITEM" KEEP="$KEEP" python3 - <<'PY'
import os, re
path, version, new_item, keep = os.environ["APPCAST"], os.environ["VERSION"], os.environ["NEW_ITEM"], int(os.environ["KEEP"])

header = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '  <channel>\n'
    '    <title>KeyScribe</title>\n'
    '    <link>https://raw.githubusercontent.com/rsperko/keyscribe/main/appcast.xml</link>\n'
    '    <description>KeyScribe app updates</description>\n'
    '    <language>en</language>\n'
)
footer = '  </channel>\n</rss>\n'

existing = ""
try:
    with open(path) as f:
        existing = f.read()
except FileNotFoundError:
    pass

items = re.findall(r"    <item>.*?    </item>", existing, re.DOTALL)
# Drop any prior item for this version (re-release), then prepend the fresh one, newest first.
items = [it for it in items if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in it]
items = [new_item] + items
items = items[:keep]

with open(path, "w") as f:
    f.write(header + "\n".join(items) + "\n" + footer)
PY

echo "appcast: upserted $VERSION (build $BUILD) → $APPCAST"
echo "  enclosure: $ENCLOSURE_URL"
