#!/usr/bin/env bash
# Compare every installed STT engine over the clips you recorded with record.sh, then print a ranked
# report (biased WER · bias-term recall · speed) and a recommended pick. Records nothing — it scores the
# *.wav files already in this folder against manifest.json's ground truth, then ranks the results.
#
# Usage:
#   bash benchmark/compare.sh                                       # compare every installed engine
#   bash benchmark/compare.sh --engines qwen3-asr-0.6b,parakeet     # only these engine ids
#   bash benchmark/compare.sh --fuzzy                               # also apply the post-STT fuzzy corrector
#   bash benchmark/compare.sh --raw                                 # raw per-clip transcripts, no scoring
#   bash benchmark/compare.sh --bin /path/to/KeyScribe              # use a specific build
#
# Engine ids: parakeet · parakeet-tdt-ctc-110m · whisper · whisper-small-en · apple ·
#             qwen3-asr-0.6b · qwen3-asr-1.7b · moonshine-base-en
# Engines whose models you have not installed are skipped — install the ones you want to compare from
# Settings → Speech Models first, or limit the set with --engines to avoid downloading all of them.
set -euo pipefail
SELF="$(basename "$0")"
cd "$(dirname "$0")"
BENCH_DIR="$PWD"
ROOT="$(cd .. && pwd)"

PASS=()        # flags forwarded verbatim to the --benchmark run
RAW=0
BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engines) PASS+=(--engines "$2"); shift 2 ;;
    --fuzzy)   PASS+=(--fuzzy); shift ;;
    --raw)     PASS+=(--raw); RAW=1; shift ;;
    --bin)     BIN="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$SELF"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

BIN="${BIN:-$ROOT/.build/release/KeyScribe}"
if [ ! -x "$BIN" ]; then
  echo "benchmark binary not found at: $BIN" >&2
  echo "Build it once (bundles the MLX metallib Qwen3 needs):  ./make-app.sh release" >&2
  echo "or point at another build with:  bash benchmark/compare.sh --bin /path/to/KeyScribe" >&2
  exit 1
fi

shopt -s nullglob
wavs=( *.wav )
if [ ${#wavs[@]} -eq 0 ]; then
  echo "no recordings in $BENCH_DIR — record some first:  bash benchmark/record.sh --tier T2" >&2
  exit 1
fi
echo "Scoring ${#wavs[@]} recordings in $BENCH_DIR …"
echo

if [ ${#PASS[@]} -gt 0 ]; then
  "$BIN" --benchmark "$BENCH_DIR" "${PASS[@]}"
else
  "$BIN" --benchmark "$BENCH_DIR"
fi

# --raw dumps transcripts and writes no results.json — there is nothing to rank.
[ "$RAW" -eq 1 ] && exit 0
[ -f results.json ] || { echo "no results.json produced — no installed engines matched?" >&2; exit 1; }

python3 - results.json <<'PY'
import json, sys
res = json.load(open(sys.argv[1]))

SIZE = {  # approx download (MB), from SpeechModelCatalog — powers the "lightest that works" pick
    "moonshine-base-en": 141, "whisper-small-en": 217, "parakeet-tdt-ctc-110m": 440,
    "whisper": 632, "qwen3-asr-0.6b": 1500, "parakeet": 1800, "qwen3-asr-1.7b": 2000,
    "apple": 0,
}
NAME = {
    "moonshine-base-en": "Moonshine Base (EN)", "whisper-small-en": "Whisper Small (EN)",
    "parakeet-tdt-ctc-110m": "Parakeet TDT-CTC 110M", "whisper": "Whisper Large v3 Turbo",
    "qwen3-asr-0.6b": "Qwen3-ASR 0.6B", "parakeet": "Parakeet TDT v3",
    "qwen3-asr-1.7b": "Qwen3-ASR 1.7B", "apple": "Apple Speech",
}

rows = [(eid, r) for eid, r in res.items() if r.get("clips", 0) > 0]
if not rows:
    print("no scored engines — install at least one model and re-run.")
    sys.exit(0)
rows.sort(key=lambda kv: kv[1]["werBiased"])

def pct(v):  return f"{v*100:5.1f}%" if v is not None and v >= 0 else "  n/a"
def mb(eid):
    s = SIZE.get(eid)
    if s is None: return "?"
    if s == 0:    return "system"
    return f"{s/1000:.1f}GB" if s >= 1000 else f"{s}MB"

print("\n══ Engine comparison (lowest biased WER first) ══\n")
print(f"  {'engine':<24}{'WER(bias)':>11}{'recall(bias)':>14}{'RTF':>8}{'clips':>7}{'install':>9}")
print("  " + "─" * 71)
for eid, r in rows:
    print(f"  {NAME.get(eid, eid):<24}{pct(r['werBiased']):>11}{pct(r.get('recallBiased', -1)):>14}"
          f"{r['rtf']:>8.3f}{int(r['clips']):>7}{mb(eid):>9}")

best_eid, best = rows[0]
best_wer = best["werBiased"]
best_rec = best.get("recallBiased", -1)

# "Lightest that stays close": within 1.0pt WER and 5pt recall of the best, smallest install.
WER_TOL, REC_TOL = 0.010, 0.05
close = [eid for eid, r in rows
         if r["werBiased"] <= best_wer + WER_TOL
         and (best_rec < 0 or r.get("recallBiased", -1) >= best_rec - REC_TOL)]
light = min(close, key=lambda e: SIZE.get(e, 10**9)) if close else best_eid
fast_eid, fast = min(rows, key=lambda kv: kv[1]["rtf"])

print("\n  Recommendations")
print(f"    • Best accuracy           {NAME.get(best_eid, best_eid)}  ({pct(best_wer)} WER)")
print(f"    • Lightest that stays close  {NAME.get(light, light)}  ({mb(light)} install)")
print(f"    • Fastest                 {NAME.get(fast_eid, fast_eid)}  (RTF {fast['rtf']:.3f})")
print("\n  Pick the lightest engine whose WER(bias) and recall(bias) stay close to the best — RTF < 1.0")
print("  means faster than real time, so speed is rarely the deciding factor. recall = fraction of your")
print("  dictionary/bias terms the engine recovered.\n")
PY
