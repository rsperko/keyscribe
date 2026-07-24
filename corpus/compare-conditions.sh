#!/usr/bin/env bash
# Compare two benchmark runs of the SAME sentences recorded under different conditions — e.g. the
# clean corpus/stt takes vs their corpus/stt-noisy twins, or a noisy corpus vs a denoised copy of it.
# Reads the results.json each dir's --benchmark run already wrote (this script transcribes nothing),
# pairs clips by id, and prints the per-engine damage: ΔWER, Δrecall, the worst-degrading clips, and
# bias terms that flipped from recovered to missed.
#
# Usage:
#   bash corpus/compare-conditions.sh corpus/stt corpus/stt-noisy            # clean vs noisy
#   bash corpus/compare-conditions.sh corpus/stt-noisy corpus/stt-noisy-df3  # noisy vs denoised
#   bash corpus/compare-conditions.sh A B --fuzzy                            # compare results-fuzzy.json
#
# Run `KeyScribe --benchmark <dir>` on both dirs first. Per-clip sections need results written by a
# build that records the "clips" map; without it you still get the aggregate table.
set -euo pipefail
SELF="$(basename "$0")"

FUZZY=0
DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fuzzy) FUZZY=1; shift ;;
    -h|--help) sed -n '2,13p' "$(dirname "$0")/$SELF"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) DIRS+=("$1"); shift ;;
  esac
done
[ ${#DIRS[@]} -eq 2 ] || { echo "usage: bash corpus/$SELF <baseline-dir> <variant-dir> [--fuzzy]" >&2; exit 2; }

NAME=results.json
[ "$FUZZY" -eq 1 ] && NAME=results-fuzzy.json
A="${DIRS[0]}/$NAME"
B="${DIRS[1]}/$NAME"
for f in "$A" "$B"; do
  [ -f "$f" ] || { echo "missing $f — run KeyScribe --benchmark on that dir first" >&2; exit 1; }
done

python3 - "$A" "$B" <<'PY'
import json, sys

pa, pb = sys.argv[1], sys.argv[2]
ra, rb = json.load(open(pa)), json.load(open(pb))
la = pa.rsplit("/", 2)[-2]
lb = pb.rsplit("/", 2)[-2]

ea, eb = ra.get("engines", {}), rb.get("engines", {})
shared = sorted(set(ea) & set(eb), key=lambda e: ea[e].get("werBiased", 9))
only_a, only_b = sorted(set(ea) - set(eb)), sorted(set(eb) - set(ea))
if not shared:
    print("no engine appears in both results files — nothing to compare"); sys.exit(1)
for label, extra in ((la, only_a), (lb, only_b)):
    if extra:
        print(f"note: engines only in {label}, skipped: {', '.join(extra)}")

def pct(v): return f"{v*100:5.1f}%" if v is not None and v >= 0 else "  n/a"

print(f"\n══ {la} → {lb} (per-engine, sorted by {la} biased WER) ══\n")
print(f"  {'engine':<24}{'WER ' + la:>16}{'WER ' + lb:>16}{'ΔWER':>8}{'recall Δ':>10}")
print("  " + "─" * 74)
for eid in shared:
    a, b = ea[eid], eb[eid]
    dw = b["werBiased"] - a["werBiased"]
    rec_a, rec_b = a.get("recallBiased", -1), b.get("recallBiased", -1)
    drec = f"{(rec_b - rec_a)*100:+5.1f}pt" if rec_a >= 0 and rec_b >= 0 else "    n/a"
    print(f"  {eid:<24}{pct(a['werBiased']):>16}{pct(b['werBiased']):>16}{dw*100:+7.1f}pt{drec:>10}")

ca, cb = ra.get("clips", {}), rb.get("clips", {})
if not ca or not cb:
    print("\n(no per-clip data in one or both results files — re-run --benchmark with a current build")
    print(" to get worst-clip and recall-flip breakdowns)")
    sys.exit(0)

mismatch = False
for eid in shared:
    ids_a, ids_b = set(ca.get(eid, {})), set(cb.get(eid, {}))
    if ids_a and ids_b and ids_a != ids_b:
        mismatch = True
        print(f"\nwarning: {eid} clip sets differ — only in {la}: {sorted(ids_a - ids_b)}"
              f"  only in {lb}: {sorted(ids_b - ids_a)}")
if mismatch:
    print("comparing the intersection only.")

print(f"\n══ Worst-degrading clips per engine (ΔWER {la} → {lb}) ══")
for eid in shared:
    rows_a, rows_b = ca.get(eid, {}), cb.get(eid, {})
    common = set(rows_a) & set(rows_b)
    if not common: continue
    deltas = sorted(
        ((cid, rows_b[cid]["werBiased"] - rows_a[cid]["werBiased"]) for cid in common),
        key=lambda kv: -kv[1])
    worst = [(cid, d) for cid, d in deltas[:8] if d > 0]
    improved = sum(1 for _, d in deltas if d < 0)
    same = sum(1 for _, d in deltas if d == 0)
    print(f"\n  {eid}  ({len(common)} paired clips: {sum(1 for _, d in deltas if d > 0)} worse, "
          f"{same} unchanged, {improved} better)")
    for cid, d in worst:
        print(f"    {cid:<6} {rows_a[cid]['werBiased']*100:5.1f}% → {rows_b[cid]['werBiased']*100:5.1f}%  ({d*100:+.1f}pt)")

flips = []
for eid in shared:
    rows_a, rows_b = ca.get(eid, {}), cb.get(eid, {})
    for cid in set(rows_a) & set(rows_b):
        rec_a, rec_b = rows_a[cid].get("recallBiased"), rows_b[cid].get("recallBiased")
        if rec_a is not None and rec_b is not None and rec_a >= 1 > rec_b:
            flips.append((eid, cid, rec_b))
if flips:
    print(f"\n══ Bias-term recall flips (recovered in {la}, missed in {lb}) ══\n")
    for eid, cid, rec_b in sorted(flips):
        print(f"  {eid:<24} {cid:<6} recall {pct(rec_b)}")
else:
    print(f"\n(no bias-term recall flips: every term recovered in {la} was also recovered in {lb})")
PY
