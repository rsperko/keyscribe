#!/usr/bin/env bash
# Run the test suite against a restrictive stand-in AI service catalog, the way a downstream build swaps
# AIServiceCatalog.swift and its public-lineup tests. The public catalog permits everything, so a test or a
# seam that leans on the public lineup stays green upstream and breaks only downstream; this is what catches it.
#
#   scripts/check-catalog-contract.sh
#
# It never touches the working tree: it syncs the tracked and unignored files into a copy outside the
# checkout, replaces the two catalog files there from scripts/catalog-contract/, and runs `swift test` in the
# copy. The copy is kept between runs so SwiftPM rebuilds incrementally. KEYSCRIBE_CATALOG_CONTRACT_DIR moves it.
# Runs take turns on a lock, and the test run is bounded by KEYSCRIBE_CATALOG_CONTRACT_TIMEOUT seconds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${KEYSCRIBE_CATALOG_CONTRACT_DIR:-$HOME/Library/Caches/keyscribe-catalog-contract}"
COPY="$WORK/src"
LOG="$WORK/swift-test.log"
TEST_LIMIT="${KEYSCRIBE_CATALOG_CONTRACT_TIMEOUT:-1500}"
LOCK_WAIT=900
mkdir -p "$COPY"

command -v timeout >/dev/null 2>&1 || { echo "!! GNU timeout not found — brew install coreutils" >&2; exit 2; }

# A second run would re-sync the copy under the first one's build and overwrite its log, so the whole
# sync-and-test holds the lock. lockf releases it when the holder exits, however it exits.
if [ -z "${KEYSCRIBE_CATALOG_CONTRACT_LOCKED:-}" ]; then
  status=0
  KEYSCRIBE_CATALOG_CONTRACT_LOCKED=1 lockf -t "$LOCK_WAIT" "$WORK/lock" "$ROOT/scripts/check-catalog-contract.sh" "$@" \
    || status=$?
  [ "$status" -eq 75 ] && echo "!! another catalog contract run held $WORK/lock for ${LOCK_WAIT}s" >&2
  exit "$status"
fi

python3 - "$ROOT" "$COPY" <<'PY'
import os, shutil, subprocess, sys

root, copy = sys.argv[1], sys.argv[2]
stand_ins = os.path.join(root, "scripts", "catalog-contract")
swapped = {
    "Sources/KeyScribeKit/AIServiceCatalog.swift": "AIServiceCatalog.swift",
    "Tests/KeyScribeKitTests/AIServiceCatalogTests.swift": "AIServiceCatalogTests.swift",
}
listed = subprocess.run(
    ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    check=True, capture_output=True).stdout.decode().split("\0")
missing = sorted(set(swapped) - set(listed))
if missing:
    sys.exit(f"!! the checkout no longer has {', '.join(missing)}; update the swap in {sys.argv[0]}")

wanted = {}
for rel in filter(None, listed):
    source = os.path.join(stand_ins, swapped[rel]) if rel in swapped else os.path.join(root, rel)
    if os.path.isfile(source):
        wanted[rel] = source

# Same size and mtime means unchanged; copy2 carries the mtime over, so SwiftPM sees only real edits.
for rel, source in wanted.items():
    target = os.path.join(copy, rel)
    s = os.stat(source)
    try:
        t = os.stat(target)
        if t.st_size == s.st_size and t.st_mtime_ns == s.st_mtime_ns:
            continue
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy2(source, target)

for directory, subdirectories, files in os.walk(copy):
    if directory == copy:
        subdirectories[:] = [d for d in subdirectories if d != ".build"]
    for name in files:
        path = os.path.join(directory, name)
        if os.path.relpath(path, copy) not in wanted:
            os.remove(path)
PY

BUILD_SYSTEM="$("$ROOT/scripts/swiftpm-build-system.sh" test)"
echo "== swift test against the stand-in AI service catalog (log: $LOG) =="
cd "$COPY"
status=0
# shellcheck disable=SC2086  # deliberate split: either empty or the two flag tokens
timeout --foreground -k 30 "$TEST_LIMIT" swift test $BUILD_SYSTEM >"$LOG" 2>&1 || status=$?
case "$status" in
  0)
    echo "catalog contract: the suite passes under the stand-in catalog" ;;
  124|137)
    echo "!! catalog contract: swift test did not finish within ${TEST_LIMIT}s — see $LOG" >&2
    exit 124 ;;
  *)
    grep -E "✘ Test .* recorded an issue|error:" "$LOG" | tail -40 >&2 || true
    echo "!! catalog contract: tests or seams depend on the public AI service lineup — see $LOG" >&2
    exit 1 ;;
esac
