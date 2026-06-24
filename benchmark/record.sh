#!/usr/bin/env bash
# Interactive, resumable recorder for the tiered STT corpus (manifest.json). For each prompt it shows
# the sentence + its tier/tags, waits for Enter to start, records mic → <id>.wav (16 kHz mono), and
# waits for Enter to stop. Stop any time with Ctrl-C and re-run — clips that already exist are skipped,
# so a long corpus is recorded over several sittings.
#
# Usage:
#   bash benchmark/record.sh --status                 # per-tier progress, record nothing
#   bash benchmark/record.sh                          # record every un-recorded clip (all tiers)
#   bash benchmark/record.sh --tier T1                # record only the un-recorded Tier 1 clips
#   bash benchmark/record.sh --device :2 --tier T2    # pick a mic, one tier
#   bash benchmark/record.sh 14 c27 c82               # (re)record specific ids, overwriting them
#
# Find your mic's avfoundation index:  ffmpeg -f avfoundation -list_devices true -i ""
set -euo pipefail
cd "$(dirname "$0")"

DEVICE=":0"
TIER=""
STATUS_ONLY=0
WANT=()   # explicit ids to (re)record; non-empty = overwrite those, ignore tier/skip

while [ $# -gt 0 ]; do
  case "$1" in
    --status) STATUS_ONLY=1; shift ;;
    --tier)   TIER="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    :*)       DEVICE="$1"; shift ;;            # bare ":N" still means device (back-compat)
    -*)       echo "unknown flag: $1" >&2; exit 2 ;;
    *)        WANT+=("$1"); shift ;;
  esac
done

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

# manifest.json → TSV: id \t tier \t tags \t text  (filtered by --tier if set)
python3 - "$TIER" <<'PY' > /tmp/bench_prompts.tsv
import json, sys
want_tier = sys.argv[1]
for e in json.load(open("manifest.json"))["entries"]:
    if want_tier and e.get("tier") != want_tier:
        continue
    tags = ",".join(e.get("tags", []))
    print("\t".join([e["id"], e.get("tier", "?"), tags, e["text"]]))
PY

want_match() {
  [ ${#WANT[@]} -eq 0 ] && return 0
  for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

# --status: per-tier recorded/total over the whole manifest, then exit.
if [ "$STATUS_ONLY" -eq 1 ]; then
  python3 - <<'PY'
import json, os
from collections import OrderedDict
ents = json.load(open("manifest.json"))["entries"]
tiers = OrderedDict()
for e in ents:
    t = e.get("tier", "?")
    have = os.path.exists(e["id"] + ".wav")
    d = tiers.setdefault(t, [0, 0])
    d[1] += 1
    if have: d[0] += 1
gt = [0, 0]
print("tier   recorded / total")
for t, (h, n) in tiers.items():
    print(f"  {t:<4} {h:>4} / {n}")
    gt[0] += h; gt[1] += n
print(f"  {'all':<4} {gt[0]:>4} / {gt[1]}")
missing = [e["id"] for e in ents if not os.path.exists(e["id"] + ".wav")]
if missing:
    print("\nnext un-recorded:", " ".join(missing[:12]) + (" …" if len(missing) > 12 else ""))
else:
    print("\nall clips recorded ✓")
PY
  exit 0
fi

echo "Recording from avfoundation device '$DEVICE'  (list devices: ffmpeg -f avfoundation -list_devices true -i \"\")"
echo "First run may prompt your terminal for microphone permission — grant it, then re-run."
[ -n "$TIER" ] && echo "Tier filter: $TIER"
[ ${#WANT[@]} -gt 0 ] && echo "Re-recording (overwrite): ${WANT[*]}"

# Count how many in the (filtered) set still need recording, for an [n/total] progress readout.
total=$(wc -l < /tmp/bench_prompts.tsv | tr -d ' ')
idx=0
while IFS=$'\t' read -r id tier tags text; do
  idx=$((idx + 1))
  want_match "$id" || continue
  out="$id.wav"
  # Full walk skips existing; explicit ids always overwrite.
  if [ ${#WANT[@]} -eq 0 ] && [ -f "$out" ]; then continue; fi
  rm -f "$out"
  echo
  echo "[$idx/$total] [$id · $tier · ${tags:-—}] READ ALOUD:"
  echo "    $text"
  read -r -p "  ⏎ to START… " _ </dev/tty
  ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -i "$DEVICE" -ac 1 -ar 16000 "$out" &
  pid=$!
  read -r -p "  ● recording — ⏎ to STOP " _ </dev/tty
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # Catch silent failures (no mic permission, bad device): a real clip is well over 4 KB.
  size=$(stat -f%z "$out" 2>/dev/null || echo 0)
  if [ "$size" -lt 4000 ]; then
    echo "  ⚠️  $out is ${size} bytes — recording FAILED (check mic permission / device index)."
  else
    echo "  ✓ saved $out (${size} bytes)"
  fi
done < /tmp/bench_prompts.tsv

echo
echo "Done with this pass. Re-run any time — recorded clips are skipped. Progress: bash record.sh --status"
echo "Then run the benchmark, e.g.:"
echo "  .build/release/KeyScribe --benchmark benchmark --engines qwen3-asr-0.6b,parakeet,moonshine"
