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

DEVICE=""   # empty = auto-resolve to the system default input mic BY NAME (see below)
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

# Resolve the avfoundation capture target. Selecting by numeric index (":0") is unstable: a virtual
# audio device (a screen-recorder / meeting mic, e.g. "Achelous Microphone") can insert itself at
# index 0 and push the real mic down, so ":0" silently records the virtual device — pure silence.
# Default to the *system default input device by NAME*, which avfoundation resolves regardless of
# index. An explicit --device (index or name) is always honored verbatim.
default_input_name() {
  system_profiler SPAudioDataType 2>/dev/null | awk '
    /^ {8}[A-Za-z].*:$/ { name=$0; sub(/^ +/, "", name); sub(/:$/, "", name) }
    /Default Input Device: Yes/ { print name; exit }'
}
if [ -z "$DEVICE" ]; then
  micname="$(default_input_name)"
  if [ -n "$micname" ]; then
    DEVICE=":$micname"
  else
    DEVICE=":0"
    echo "⚠️  could not resolve the default input device — falling back to index :0" >&2
  fi
fi

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
echo "While recording: ⏎ saves · type r then ⏎ to re-record · q then ⏎ to quit · Ctrl-C discards."
[ -n "$TIER" ] && echo "Tier filter: $TIER"
[ ${#WANT[@]} -gt 0 ] && echo "Re-recording (overwrite): ${WANT[*]}"

pid=""
out=""
trap 'echo; [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null; [ -n "$out" ] && rm -f "$out"; echo "interrupted — discarded ${out:-current clip}"; exit 130' INT

# Count how many in the (filtered) set still need recording, for an [n/total] progress readout.
total=$(wc -l < /tmp/bench_prompts.tsv | tr -d ' ')
idx=0
while IFS=$'\t' read -r id tier tags text; do
  idx=$((idx + 1))
  want_match "$id" || continue
  out="$id.wav"
  # Full walk skips existing; explicit ids always overwrite.
  if [ ${#WANT[@]} -eq 0 ] && [ -f "$out" ]; then continue; fi
  echo
  echo "[$idx/$total] [$id · $tier · ${tags:-—}] READ ALOUD:"
  echo "    $text"
  # Re-record loop: a clip stays current until it is saved, skipped, or quit.
  while true; do
    rm -f "$out"
    read -r -p "  ⏎ to START · s skip · q quit … " ans </dev/tty
    case "$ans" in
      q|Q) echo "  quit."; exit 0 ;;
      s|S) echo "  ↷ skipped $id"; break ;;
    esac
    ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -i "$DEVICE" -ac 1 -ar 16000 "$out" &
    pid=$!
    read -r -p "  ● recording — ⏎ STOP · r ⏎ re-record · q ⏎ quit … " ans </dev/tty
    kill -INT "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
    case "$ans" in
      r|R) echo "  ↻ re-recording ${id}…"; continue ;;
      q|Q) rm -f "$out"; echo "  quit."; exit 0 ;;
    esac
    # Catch silent failures: too-small file (no mic permission / bad device) OR a full-length file of
    # pure silence (wrong/virtual device captured — bytes look fine but every sample is at the floor).
    size=$(stat -f%z "$out" 2>/dev/null || echo 0)
    if [ "$size" -lt 4000 ]; then
      echo "  ⚠️  $out is ${size} bytes — recording FAILED (check mic permission / device index). Retrying."
      continue
    fi
    mean=$(ffmpeg -nostdin -hide_banner -i "$out" -af volumedetect -f null - 2>&1 \
           | sed -n 's/.*mean_volume: \(-*[0-9.]*\) dB.*/\1/p' | head -1)
    if [ -n "$mean" ] && awk "BEGIN{exit !($mean <= -80)}"; then
      echo "  ⚠️  $out is SILENT (${mean} dB) — '$DEVICE' captured no audio. Retrying."
      echo "      A virtual mic may have hijacked the input; pick the real mic with --device, e.g.:"
      echo "        ffmpeg -f avfoundation -list_devices true -i \"\"   # find your mic's index/name"
      continue
    fi
    echo "  ✓ saved $out (${size} bytes, ${mean:-?} dB)"
    break
  done
done < /tmp/bench_prompts.tsv

echo
echo "Done with this pass. Re-run any time — recorded clips are skipped. Progress: bash record.sh --status"
echo "Then compare engines over these recordings:"
echo "  bash benchmark/compare.sh"
