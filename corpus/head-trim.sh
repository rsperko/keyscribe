#!/usr/bin/env bash
# Quantify head-clip sensitivity of the spoken-command corpus (P2-3). Whatever a user says before the
# mic is admitted is lost; a clipped first phoneme is exactly what breaks a whole-utterance replacement
# ("slash resume" → "/resume") or a word-boundary command. This harness head-trims each recorded
# commands clip by 0/50/100/200 ms, runs the REAL --commands-check pipeline against each trimmed set,
# and reports the assertion pass-rate per trim per engine — so the exposure is a number, and P1-1's
# effect (mic-live == cue-end) is measurable before vs after.
#
# It never touches the committed manifests: trimmed clips + a copied manifest go to a scratch dir.
#
# Usage:
#   bash corpus/head-trim.sh                                  # default engine set, trims 0/50/100/200
#   bash corpus/head-trim.sh --engines parakeet-tdt-ctc-110m  # scope engines (comma-separated ids)
#   bash corpus/head-trim.sh --trims 0,100                    # custom trims (ms)
#   bash corpus/head-trim.sh --bin /path/to/KeyScribe         # use a specific build
#   bash corpus/head-trim.sh --keep                           # keep the scratch dir for inspection
#
# Qwen (MLX) needs the bundled metallib — run it via the KeyScribeDev.app binary (default when present),
# not the bare .build binary, or it dies with "Failed to load the default metallib".
set -euo pipefail
SELF="$(basename "$0")"
cd "$(dirname "$0")"
SRC_DIR="$PWD/commands"       # the committed spoken-command sub-corpus (manifest.json + <id>.wav)
ROOT="$(cd .. && pwd)"

ENGINES=""
TRIMS="0,50,100,200"
BIN=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --engines) ENGINES="$2"; shift 2 ;;
    --trims)   TRIMS="$2"; shift 2 ;;
    --bin)     BIN="$2"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,22p' "$SELF"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Prefer the signed dev app (its metallib lets Qwen run); fall back to release, then debug.
if [ -z "$BIN" ]; then
  for cand in \
    "$ROOT/KeyScribeDev.app/Contents/MacOS/KeyScribe" \
    "$ROOT/.build/release/KeyScribe" \
    "$ROOT/.build/debug/KeyScribe"; do
    [ -x "$cand" ] && { BIN="$cand"; break; }
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "commands-check binary not found. Build one first (./make-app.sh) or pass --bin /path/to/KeyScribe" >&2
  exit 1
fi

command -v ffmpeg >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)" >&2; exit 1; }

shopt -s nullglob
wavs=( "$SRC_DIR"/*.wav )
[ ${#wavs[@]} -gt 0 ] || { echo "no clips in $SRC_DIR — record some first: bash corpus/record.sh --commands" >&2; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/keyscribe-headtrim.XXXXXX")"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$SCRATCH"; }
trap cleanup EXIT

echo "Head-trim commands harness"
echo "  binary : $BIN"
echo "  clips  : ${#wavs[@]} in $SRC_DIR"
echo "  trims  : ${TRIMS} ms"
[ -n "$ENGINES" ] && echo "  engines: $ENGINES"
echo "  scratch: $SCRATCH"
echo

IFS=',' read -r -a TRIM_ARR <<< "$TRIMS"
RESULTS="$SCRATCH/results.tsv"   # trim<TAB>engine<TAB>clean<TAB>total

for ms in "${TRIM_ARR[@]}"; do
  set_dir="$SCRATCH/trim_${ms}ms"
  mkdir -p "$set_dir"
  cp "$SRC_DIR/manifest.json" "$set_dir/manifest.json"
  sec=$(python3 -c "print(f'{int('$ms')/1000:.3f}')")
  for w in "${wavs[@]}"; do
    out="$set_dir/$(basename "$w")"
    if [ "$ms" -eq 0 ]; then
      cp "$w" "$out"
    else
      # Drop the first ${ms} ms, reset PTS, keep the 16 kHz-mono capture format the engines expect.
      ffmpeg -nostdin -loglevel error -y -i "$w" \
        -af "atrim=start=${sec},asetpts=PTS-STARTPTS" -ar 16000 -ac 1 "$out"
    fi
  done

  echo "== trim ${ms} ms =="
  log="$set_dir/commands-check.log"
  if [ -n "$ENGINES" ]; then
    "$BIN" --commands-check "$set_dir" --engines "$ENGINES" | tee "$log"
  else
    "$BIN" --commands-check "$set_dir" | tee "$log"
  fi
  echo

  # Parse results. The summary block truncates engine ids to 18 chars, so read full ids from the
  # per-engine "── <id> ──" headers (printed only for loaded engines) and zip them, in order, with the
  # summary's "<name> <clean> / <total>" count lines (also only loaded engines, same order).
  python3 - "$log" "$ms" "$RESULTS" <<'PY'
import re, sys
log, ms, out = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(log, encoding="utf-8", errors="replace").read().splitlines()
ids = [m.group(1) for l in lines if (m := re.match(r"^──\s+(\S+)\s", l))]
try:
    start = next(i for i, l in enumerate(lines) if l.strip().startswith("summary"))
except StopIteration:
    sys.exit(0)
counts = []
for l in lines[start + 1:]:
    m = re.match(r"^\S.*?\s+(\d+)\s*/\s*(\d+)\s*$", l.rstrip())
    if m:
        counts.append((m.group(1), m.group(2)))
with open(out, "a", encoding="utf-8") as f:
    for eid, (clean, total) in zip(ids, counts):
        f.write(f"{ms}\t{eid}\t{clean}\t{total}\n")
PY
done

echo "════ Head-clip pass-rate matrix (assertions clean / total) ════"
python3 - "$RESULTS" "$TRIMS" <<'PY'
import sys
res, trims = sys.argv[1], [t for t in sys.argv[2].split(",") if t != ""]
data = {}   # engine -> {trim -> (clean,total)}
try:
    for line in open(res, encoding="utf-8"):
        ms, eid, clean, total = line.rstrip("\n").split("\t")
        data.setdefault(eid, {})[ms] = (int(clean), int(total))
except FileNotFoundError:
    print("no results parsed — did any engine load?")
    sys.exit(0)
if not data:
    print("no results parsed — did any engine load?")
    sys.exit(0)

cols = [f"{t}ms" for t in trims]
w = max(24, max(len(e) for e in data) + 2)
header = "  " + "engine".ljust(w) + "".join(c.rjust(12) for c in cols)
print()
print(header)
print("  " + "─" * (w + 12 * len(cols)))
for eid in sorted(data):
    cells = []
    for t in trims:
        ct = data[eid].get(t)
        if ct is None:
            cells.append("—".rjust(12)); continue
        clean, total = ct
        pct = (100 * clean / total) if total else 0
        cells.append(f"{clean}/{total} {pct:3.0f}%".rjust(12))
    print("  " + eid.ljust(w) + "".join(cells))
print()
print("  Each cell = command assertions that held / total, after dropping the first N ms of every clip.")
print("  A steep drop as N grows is head-clip exposure (worst on whole-utterance replacements). Run this")
print("  before and after P1-1 (cue/bring-up overlap) — with mic-live == cue-end, the 0 ms column should")
print("  be what real dictations now get, and the falloff quantifies what a residual clip would cost.")
PY
