#!/usr/bin/env bash
# Drive the Settings UI from a JSON action script (agent-authored). Runs the ActionRunner UI test with the
# script passed inline via environment (the sandboxed runner cannot read an arbitrary file path), then
# extracts the per-step results + screenshots from the .xcresult into UITests/actions/.
#
#   scripts/ui-drive.sh <script.json> [output-dir]
#
# Script format + supported actions: see UITests/KeyScribeUITests/ActionRunnerTests.swift.
# Prereqs: KeyScribeDev.app built (./make-app.sh); runner built + granted (scripts/ui-test.sh build && grant).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS="$ROOT/UITests/DerivedData/Logs/Test"

SCRIPT_JSON="${1:?usage: ui-drive.sh <script.json> [output-dir]}"
[ -f "$SCRIPT_JSON" ] || { echo "no such script: $SCRIPT_JSON"; exit 1; }
OUT="${2:-$ROOT/UITests/actions}"

export TEST_RUNNER_KEYSCRIBE_UI_SCRIPT_B64="$(base64 < "$SCRIPT_JSON" | tr -d '\n')"

"$SCRIPT_DIR/ui-test.sh" run -only-testing:KeyScribeUITests/ActionRunnerTests

XCRESULT="$(ls -dt "$LOGS"/*.xcresult 2>/dev/null | head -1)"
[ -n "$XCRESULT" ] || { echo "no .xcresult found under $LOGS"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$XCRESULT" --output-path "$OUT" >/dev/null

python3 - "$OUT" <<'PY'
import json, os, re, shutil, sys
d = sys.argv[1]
man = json.load(open(os.path.join(d, "manifest.json")))
suffix = re.compile(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$")
for entry in (man if isinstance(man, list) else [man]):
    for a in entry.get("attachments", []):
        s = a.get("exportedFileName")
        n = a.get("suggestedHumanReadableName") or a.get("name")
        if s and n and os.path.exists(os.path.join(d, s)):
            shutil.move(os.path.join(d, s), os.path.join(d, suffix.sub(r"\1", n)))
os.remove(os.path.join(d, "manifest.json"))
PY

echo "--- results ---"
if [ -f "$OUT/_actions.json" ]; then cat "$OUT/_actions.json"; else
  echo "(no _actions.json — the runner may not have received the script via env)"; fi
echo; echo "artifacts in $OUT:"; ls "$OUT"
