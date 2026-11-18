#!/bin/zsh
# Usage: zsh publish.sh
#   Replaces voice-kit-<study>.zip for every study on the one `voice-kit` GitHub release and moves its tag to
#   main, so the release always matches main. The kit is not versioned; links never change:
#   …/releases/download/voice-kit/voice-kit-<study>.zip
#   VOICE_KIT_DRY_RUN=<dir> builds into <dir> and uploads nothing.
set -eu
KIT="${0:A:h}"
REPO=rsperko/keyscribe
TAG=voice-kit
OUT="${VOICE_KIT_DRY_RUN:-$(mktemp -d)}"
mkdir -p "$OUT"
NOTES="$OUT/notes.md"
echo "Guided recordings that help improve speech recognition. Download the zip for the study you were asked to record and follow its steps." > "$NOTES"
assets=()
for tsv in "$KIT"/studies/*.tsv; do
  s="${tsv:t:r}"
  zsh "$KIT/package.sh" --out "$OUT/$s" "$s" >/dev/null
  mv "$OUT/$s/voice-kit.zip" "$OUT/voice-kit-$s.zip"
  assets+=("$OUT/voice-kit-$s.zip")
  {
    echo; echo "---"; echo
    echo "**Download: [voice-kit-$s.zip](https://github.com/$REPO/releases/download/$TAG/voice-kit-$s.zip)**"
    echo
    [ -f "$OUT/$s/$s-invite.md" ] && sed 's/^#/##/' "$OUT/$s/$s-invite.md"
  } >> "$NOTES"
done
[ -n "${VOICE_KIT_DRY_RUN:-}" ] && { echo "dry run: $OUT"; exit 0; }

cd "$KIT"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "error: publish from main as pushed (HEAD is not origin/main)." >&2; exit 1; }
[ -z "$(git status --porcelain -- .)" ] || { echo "error: voice-kit/ has uncommitted changes; commit and push them first." >&2; exit 1; }

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  git push -q -f origin "HEAD:refs/tags/$TAG"
  gh release upload "$TAG" "${assets[@]}" -R "$REPO" --clobber
  gh release edit "$TAG" -R "$REPO" --notes-file "$NOTES"
else
  gh release create "$TAG" "${assets[@]}" -R "$REPO" --target main --prerelease --latest=false \
    --title "Voice kit" --notes-file "$NOTES"
fi
echo "https://github.com/$REPO/releases/tag/$TAG"
