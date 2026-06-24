#!/usr/bin/env bash
# Record YOUR voice for the same phrases the synthetic voice corpus uses, so we can compare how the
# STT engines punctuate a real spoken "scratch that" correction vs. synthetic TTS. The whole question
# is prosodic — whether your natural pause around the keyword makes the engine emit a sentence
# terminator — so speak each line the way the guidance says. Clips land as <id>__human.wav (16 kHz
# mono) and are added to manifest.json; then re-run:  KeyScribe --benchmark benchmark/voices --raw
#
# Usage:   bash benchmark/voices/record-human.sh            # record all (skips ones already done)
#          bash benchmark/voices/record-human.sh --device :2
#          bash benchmark/voices/record-human.sh cmd_runon  # (re)record one id, overwriting
#
# Find your mic index:  ffmpeg -f avfoundation -list_devices true -i ""
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

DEVICE=":0"
WANT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    :*)       DEVICE="$1"; shift ;;
    -*)       echo "unknown flag: $1" >&2; exit 2 ;;
    *)        WANT+=("$1"); shift ;;
  esac
done

# pid <TAB> kind <TAB> expectTerminator <TAB> text <TAB> how-to-speak-it
PROMPTS=$(cat <<'P'
cmd_pause	command	yes	We went up the hill, scratch that. We went down the hill.	Pause briefly where the comma is, as if catching yourself.
cmd_runon	command	yes	We went up the hill scratch that we went down the hill	Say it in ONE breath, no real pause — correct yourself mid-flow.
cmd_after	command	yes	We went up the hill. Scratch that. We went down the hill.	Full stop after "hill", then "Scratch that." as its own beat.
cmd_end	command	yes	I think the meeting is on Tuesday scratch that	Trail off into "scratch that" at the very end, then stop.
lit_ticket	literal	no	I told her to scratch that lottery ticket and see if we won	Normal sentence — "scratch that lottery ticket" flows together.
lit_itch	literal	no	Let me scratch that itch real quick	Normal sentence, no pause (literal use).
P
)

want_match() { [ ${#WANT[@]} -eq 0 ] && return 0; for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

echo "Recording from avfoundation device '$DEVICE'. First run may prompt for mic permission."
while IFS=$'\t' read -r pid kind expect text how; do
  [ -z "${pid:-}" ] && continue
  want_match "$pid" || continue
  out="${pid}__human.wav"
  if [ ${#WANT[@]} -eq 0 ] && [ -f "$out" ]; then echo "skip (exists): $out"; continue; fi
  rm -f "$out"
  echo
  echo "[$pid · $kind] READ ALOUD:"
  echo "    $text"
  echo "  how: $how"
  read -r -p "  ⏎ to START… " _ </dev/tty
  ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation -i "$DEVICE" -ac 1 -ar 16000 "$out" &
  fpid=$!
  read -r -p "  ● recording — ⏎ to STOP " _ </dev/tty
  kill -INT "$fpid" 2>/dev/null || true
  wait "$fpid" 2>/dev/null || true
  size=$(stat -f%z "$out" 2>/dev/null || echo 0)
  if [ "$size" -lt 4000 ]; then
    echo "  ⚠️  $out is ${size} bytes — recording FAILED (check mic permission / device index)."
  else
    echo "  ✓ saved $out (${size} bytes)"
  fi
done <<<"$PROMPTS"

python3 - <<'PY'
import json, os
man = "manifest.json"
data = json.load(open(man)) if os.path.exists(man) else {"entries": []}
by_id = {e["id"]: e for e in data["entries"]}
prompts = [
    ("cmd_pause","command","yes","We went up the hill, scratch that. We went down the hill."),
    ("cmd_runon","command","yes","We went up the hill scratch that we went down the hill"),
    ("cmd_after","command","yes","We went up the hill. Scratch that. We went down the hill."),
    ("cmd_end","command","yes","I think the meeting is on Tuesday scratch that"),
    ("lit_ticket","literal","no","I told her to scratch that lottery ticket and see if we won"),
    ("lit_itch","literal","no","Let me scratch that itch real quick"),
]
added = 0
for pid, kind, expect, text in prompts:
    cid = f"{pid}__human"
    if os.path.exists(f"{cid}.wav") and cid not in by_id:
        data["entries"].append({"id": cid, "text": text, "biasTerms": [],
                                "kind": kind, "expectTerminator": expect, "voice": "human"})
        added += 1
json.dump(data, open(man, "w"), indent=2)
print(f"manifest: added {added} human entries ({sum(1 for e in data['entries'] if e.get('voice')=='human')} total)")
PY

echo
echo "Now re-run the raw dump + analysis:"
echo "  .build/release/KeyScribe --benchmark benchmark/voices --raw > /tmp/raw.txt 2>/dev/null"
