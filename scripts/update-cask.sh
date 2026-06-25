#!/usr/bin/env bash
# Refresh the Homebrew cask in the tap from the current release: reads the version from the latest git
# tag and the sha256 from the built KeyScribe-<version>.dmg, then writes Casks/keyscribe.rb into the
# tap. Local only — it does NOT commit or push (that stays a deliberate step). Run after ./release.sh.
#
#   KEYSCRIBE_TAP_DIR   path to the homebrew-tap checkout (default ../homebrew-tap).
set -euo pipefail
cd "$(dirname "$0")/.."

TAP_DIR="${KEYSCRIBE_TAP_DIR:-../homebrew-tap}"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$VERSION" ] || { echo "error: no git tag — cut a release first (./release.sh vX.Y.Z)." >&2; exit 1; }
DMG="KeyScribe-$VERSION.dmg"
[ -f "$DMG" ] || { echo "error: $DMG not found — run ./release.sh to build it first." >&2; exit 1; }
[ -d "$TAP_DIR" ] || { echo "error: tap not found at $TAP_DIR — set KEYSCRIBE_TAP_DIR." >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
CASK="$TAP_DIR/Casks/keyscribe.rb"
mkdir -p "$TAP_DIR/Casks"
cat > "$CASK" <<EOF
cask "keyscribe" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/rsperko/keyscribe/releases/download/v#{version}/KeyScribe-#{version}.dmg"
  name "KeyScribe"
  desc "Privacy-first, local-first voice dictation for macOS"
  homepage "https://github.com/rsperko/keyscribe"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "KeyScribe.app"

  zap trash: [
    "~/Library/Application Support/KeyScribe",
    "~/Library/Preferences/com.keyscribe.app.plist",
  ]
end
EOF

echo "wrote $CASK  (version $VERSION, sha256 $SHA)"
echo "next, in the tap: (cd $TAP_DIR && git add Casks/keyscribe.rb && git commit -m \"keyscribe $VERSION\" && git push)"
