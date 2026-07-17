#!/usr/bin/env bash
# Regenerate the silence-lead clips from the committed stt recordings. Each derived clip prepends a
# fixed leading span onto a human stt clip: digital silence for `lead_<base>_<N>s`, faint hiss
# (a=0.02, the quiet-room level from the engine silence sweep) for `lead_<base>_hiss<N>s`. Clip ids
# encode the derivation, so this script needs no table — it parses the manifest and rebuilds every
# derived wav. Ids that don't match the pattern (e.g. a hand-added real repro clip) are left alone.
#
# Wavs are gitignored like every sub-corpus; run this after recording/refreshing the stt corpus.
#
# Usage: bash corpus/silence-lead/gen.sh
set -euo pipefail
cd "$(dirname "$0")"
STT=../stt

command -v ffmpeg >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)" >&2; exit 1; }

ids=$(python3 -c '
import json
for c in json.load(open("manifest.json"))["clips"]:
    print(c["id"])
')

made=0 skipped=0 kept=0
for id in $ids; do
  if [[ "$id" =~ ^lead_([A-Za-z0-9]+)_hiss([0-9]+)s$ ]]; then
    base="${BASH_REMATCH[1]}"; dur="${BASH_REMATCH[2]}"
    lead=(-f lavfi -t "$dur" -i "anoisesrc=r=16000:a=0.02:seed=33")
  elif [[ "$id" =~ ^lead_([A-Za-z0-9]+)_([0-9]+)s$ ]]; then
    base="${BASH_REMATCH[1]}"; dur="${BASH_REMATCH[2]}"
    lead=(-f lavfi -t "$dur" -i "anullsrc=r=16000:cl=mono")
  else
    echo "  keep   ${id}.wav (not derived — expected to be a real recording)"
    kept=$((kept + 1))
    continue
  fi
  src="$STT/${base}.wav"
  if [ ! -f "$src" ]; then
    echo "  skip   ${id}.wav (missing base $src — record the stt corpus first)"
    skipped=$((skipped + 1))
    continue
  fi
  ffmpeg -nostdin -loglevel error -y "${lead[@]}" -i "$src" \
    -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1" -ar 16000 -ac 1 -c:a pcm_s16le "${id}.wav"
  echo "  made   ${id}.wav (${dur}s lead + ${base}.wav)"
  made=$((made + 1))
done
echo "done: $made generated, $skipped skipped, $kept kept"
