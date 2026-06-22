#!/usr/bin/env bash
# Interactive recorder for the STT benchmark. Walks the prompts in manifest.json: for each, it shows
# the sentence to read, waits for Enter to start, records mic → <id>.wav (16 kHz mono), and waits for
# Enter to stop. Re-runnable: clips that already exist are skipped, so you can stop and resume.
#
# Find your mic's avfoundation index first:
#   ffmpeg -f avfoundation -list_devices true -i ""
# Record everything (default device :0):
#   bash benchmark/record.sh ":2"
# Re-record only specific clips (overwrites them):
#   bash benchmark/record.sh ":2" 10 14
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${1:-:0}"
shift || true
WANT=("$@")   # optional explicit ids to (re)record; empty = walk all, skipping existing
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

want_match() {
  [ ${#WANT[@]} -eq 0 ] && return 0
  for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

python3 - <<'PY' > /tmp/bench_prompts.tsv
import json
for e in json.load(open("manifest.json"))["entries"]:
    print(e["id"] + "\t" + e["text"])
PY

echo "Recording from avfoundation device '$DEVICE' (override: bash record.sh \":N\")"
echo "First run may prompt your terminal for microphone permission — grant it, then re-run."

while IFS=$'\t' read -r id text; do
  want_match "$id" || continue
  out="$id.wav"
  # Skip existing only on a full walk; explicit ids always re-record (overwrite).
  if [ ${#WANT[@]} -eq 0 ] && [ -f "$out" ]; then echo "✓ $out exists — skipping"; continue; fi
  rm -f "$out"
  echo
  echo "[$id] READ ALOUD:"
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
    echo "  saved $out (${size} bytes)"
  fi
done < /tmp/bench_prompts.tsv

echo
echo "All prompts done. Re-run to redo any clip after deleting its .wav."
echo "Then: .build/release/KeyScribe --benchmark benchmark --engines qwen3-asr-0.6b,whisper,parakeet"
