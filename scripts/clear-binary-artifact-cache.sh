#!/usr/bin/env bash
# Recover from SwiftPM's changed-checksum guard after an upstream dependency
# re-uploads a binaryTarget asset in place.
#
#   error: artifact of binary target 'X' has changed checksum; this is a
#          potential security risk so the new artifact won't be downloaded
#
# Pulling the corrected pin is NOT enough: SwiftPM refuses to re-download while
# it still holds a record of the old checksum, and its global download cache is
# keyed by URL — which did not change — so it still holds the OLD bytes. Three
# places have to be cleared, and the global one is the easy one to miss.
#
# Defaults to a dry run. Pass --apply to actually delete.
#
#   scripts/clear-binary-artifact-cache.sh                    # show what is stale
#   scripts/clear-binary-artifact-cache.sh --apply            # clear everything
#   scripts/clear-binary-artifact-cache.sh --apply moonshine-swift
#
# Afterwards: swift package resolve   (re-downloads and re-validates)

set -euo pipefail

cd "$(dirname "$0")/.."

APPLY=0
PACKAGES=()
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) PACKAGES+=("$arg") ;;
  esac
done

STATE=".build/workspace-state.json"
GLOBAL_CACHE="${HOME}/Library/Caches/org.swift.swiftpm/artifacts"
BOLD=$'\033[1m'; DIM=$'\033[2m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

wanted() {
  [ ${#PACKAGES[@]} -eq 0 ] && return 0
  local candidate
  for candidate in "${PACKAGES[@]}"; do [ "$candidate" = "$1" ] && return 0; done
  return 1
}

if [ ! -f "$STATE" ]; then
  echo "no $STATE — nothing resolved yet, so there is no stale artifact record."
  echo "if a global cache entry is still stale, clear it by hand under:"
  echo "  $GLOBAL_CACHE"
  exit 0
fi

# identity <TAB> url, one per recorded binary artifact
ARTIFACTS=$(python3 - "$STATE" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle)
for artifact in doc.get("object", {}).get("artifacts", []):
    identity = artifact.get("packageRef", {}).get("identity", "")
    url = artifact.get("source", {}).get("url", "")
    if identity and url:
        print(f"{identity}\t{url}")
PY
)

if [ -z "$ARTIFACTS" ]; then
  echo "no binary artifacts recorded in $STATE."
  exit 0
fi

[ "$APPLY" = 1 ] || echo "${YELLOW}dry run${RESET} — re-run with --apply to delete${DIM} (sizes are what will be re-downloaded)${RESET}"
echo

CLEARED=0
while IFS=$'\t' read -r IDENTITY URL; do
  [ -n "$IDENTITY" ] || continue
  wanted "$IDENTITY" || continue

  # SwiftPM keys its global download cache by the URL with every
  # non-alphanumeric byte replaced by an underscore.
  KEY=$(printf '%s' "$URL" | LC_ALL=C tr -c 'A-Za-z0-9' '_')
  EXTRACTED=".build/artifacts/$IDENTITY"
  CACHED="$GLOBAL_CACHE/$KEY"

  echo "${BOLD}$IDENTITY${RESET} ${DIM}$URL${RESET}"
  for TARGET in "$EXTRACTED" "$CACHED"; do
    if [ -e "$TARGET" ]; then
      SIZE=$(du -sh "$TARGET" 2>/dev/null | cut -f1)
      if [ "$APPLY" = 1 ]; then
        rm -rf "$TARGET"
        echo "  ${GREEN}removed${RESET} $TARGET ${DIM}($SIZE)${RESET}"
      else
        echo "  would remove $TARGET ${DIM}($SIZE)${RESET}"
      fi
      CLEARED=$((CLEARED + 1))
    else
      echo "  ${DIM}absent${RESET}    $TARGET"
    fi
  done

  if [ "$APPLY" = 1 ]; then
    python3 - "$STATE" "$IDENTITY" <<'PY'
import json, sys
path, identity = sys.argv[1], sys.argv[2]
with open(path) as handle:
    doc = json.load(handle)
artifacts = doc.get("object", {}).get("artifacts", [])
kept = [a for a in artifacts if a.get("packageRef", {}).get("identity") != identity]
doc["object"]["artifacts"] = kept
with open(path, "w") as handle:
    json.dump(doc, handle, indent=2)
print(f"  \033[32mremoved\033[0m {identity} record from {path}")
PY
  else
    echo "  would remove $IDENTITY record from $STATE"
  fi
  echo
done <<< "$ARTIFACTS"

if [ "$APPLY" = 1 ]; then
  echo "${GREEN}done${RESET} — now run: ${BOLD}swift package resolve${RESET}"
  echo "${DIM}(release builds: KEYSCRIBE_SPARKLE=1 swift package resolve, so Sparkle stays pinned)${RESET}"
else
  [ "$CLEARED" -gt 0 ] && echo "re-run with --apply to clear the above."
fi
