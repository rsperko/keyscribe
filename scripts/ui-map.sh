#!/usr/bin/env bash
# Regenerate the agent-facing UI map. Runs the InventoryDump UI test (which walks every Settings pane +
# the mode editor and emits per-pane element JSON + a screenshot as XCTAttachments, plus _gaps.json), then
# extracts those attachments out of the .xcresult and renames them to UITests/map/<pane>.json|png.
#
# The runner is sandboxed, so the test CANNOT write UITests/map/ directly -- attachments are the only
# reliable channel out. This script is the extraction half.
#
# Prereqs: KeyScribeDev.app built (./make-app.sh) and the runner built + granted Accessibility once
#   (scripts/ui-test.sh build && scripts/ui-test.sh grant). Then: scripts/ui-map.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAP="$ROOT/UITests/map"
LOGS="$ROOT/UITests/DerivedData/Logs/Test"

"$SCRIPT_DIR/ui-test.sh" run -only-testing:KeyScribeUITests/InventoryDumpTests

XCRESULT="$(ls -dt "$LOGS"/*.xcresult 2>/dev/null | head -1)"
[ -n "$XCRESULT" ] || { echo "no .xcresult found under $LOGS"; exit 1; }

rm -rf "$MAP"; mkdir -p "$MAP"
xcrun xcresulttool export attachments --path "$XCRESULT" --output-path "$MAP" >/dev/null

# xcresulttool names files by UUID; manifest.json maps each to its attachment name (e.g.
# "general_0_<uuid>.json"). Rename to the clean pane name by stripping the "_<index>_<uuid>" suffix.
python3 - "$MAP" <<'PY'
import json, os, re, shutil, sys
mapdir = sys.argv[1]
manifest = json.load(open(os.path.join(mapdir, "manifest.json")))
suffix = re.compile(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$")
n = 0
for entry in (manifest if isinstance(manifest, list) else [manifest]):
    for a in entry.get("attachments", []):
        src = a.get("exportedFileName")
        name = a.get("suggestedHumanReadableName") or a.get("name")
        if not src or not name:
            continue
        clean = suffix.sub(r"\1", name)
        s = os.path.join(mapdir, src)
        if os.path.exists(s):
            shutil.move(s, os.path.join(mapdir, clean))
            n += 1
os.remove(os.path.join(mapdir, "manifest.json"))
print(f"map written to {mapdir} ({n} artifacts)")
PY

echo "--- gaps ---"
python3 -c "
import json
g = json.load(open('$MAP/_gaps.json'))
print(f'{len(g)} real gap(s):')
for e in g:
    print(f\"  {e['pane']:12} {e['role']:11} label={e.get('label','')!r}\")
" 2>/dev/null || echo "(no _gaps.json)"
