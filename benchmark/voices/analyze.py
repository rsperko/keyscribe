#!/usr/bin/env python3
# Analyze a `--raw` STT dump over this corpus: for each transcript, classify what immediately follows
# "scratch that" — TERM (./!/?), COMMA, END (utterance end), CONT (a continuing word), or ABSENT
# (engine didn't transcribe the phrase). The LiveEditsStage rule fires the command on TERM/COMMA/END
# and treats CONT as literal text, so this shows, per engine: command capture (TERM/COMMA/END on
# command clips) vs. literal safety (anything but CONT on literal clips is a false boundary).
#   .build/release/KeyScribe --benchmark benchmark/voices --raw > /tmp/raw.txt 2>/dev/null
#   python benchmark/voices/analyze.py /tmp/raw.txt
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
meta = {e["id"]: e for e in json.load(open(HERE / "manifest.json"))["entries"]}
raw_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/raw.txt"

ENG_ORDER = ["parakeet", "parakeet-tdt-ctc-110m", "whisper", "apple",
             "qwen3-asr-0.6b", "qwen3-asr-1.7b", "moonshine-base-en"]
CATS = ["TERM", "COMMA", "END", "CONT", "ABSENT"]


def classify(hyp: str) -> str:
    m = re.search(r"scratch(?:ed)?\s+that", hyp, re.IGNORECASE)
    if not m:
        return "ABSENT"
    rest = hyp[m.end():]
    if rest.strip() == "":
        return "END"
    return {".": "TERM", "!": "TERM", "?": "TERM", ",": "COMMA"}.get(rest[0], "CONT")


cmd = defaultdict(lambda: defaultdict(int))
lit = defaultdict(lambda: defaultdict(int))
for line in open(raw_path):
    if not line.startswith("RAW\t"):
        continue
    _, engine, cid, hyp = line.rstrip("\n").split("\t", 3)
    if cid not in meta:
        continue
    bucket = cmd if meta[cid]["kind"] == "command" else lit
    bucket[engine][classify(hyp)] += 1


def table(title, data):
    print(f"\n=== {title} ===")
    print(f"{'engine':24} " + "  ".join(f"{c:>6}" for c in CATS) + "    n")
    for e in ENG_ORDER:
        d = data.get(e)
        if not d:
            continue
        print(f"{e:24} " + "  ".join(f"{d.get(c, 0):>6}" for c in CATS) + f"  {sum(d.values()):>3}")


print("COMMAND clips — TERM/COMMA/END = command fires; CONT = missed (treated as literal)")
table("COMMAND", cmd)
print("\nLITERAL clips — CONT = correctly left as text; TERM/COMMA/END = false boundary (would misfire)")
table("LITERAL", lit)
