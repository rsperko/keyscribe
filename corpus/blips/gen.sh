#!/usr/bin/env bash
# Derives the dbl_* two-noise takes from the recorded blip_* clips: two real blips separated by a
# silence gap, which is the case a "count total clearing chunks" admission rule could in principle
# admit but a "longest consecutive run" rule could not. Regenerate after re-recording the blips.
#
# Usage: bash corpus/blips/gen.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v ffmpeg >/dev/null || { echo "ffmpeg required"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mk() { # $1=out  $2=first blip  $3=gap seconds  $4=second blip
  for src in "$2" "$4"; do
    [ -f "$src.wav" ] || { echo "missing $src.wav — record the blips first"; exit 1; }
  done
  ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=24000:cl=mono -t "$3" -c:a pcm_f32le "$tmp/gap.wav"
  ffmpeg -y -loglevel error -i "$2.wav" -i "$tmp/gap.wav" -i "$4.wav" \
    -filter_complex "[0:a][1:a][2:a]concat=n=3:v=0:a=1" -c:a pcm_f32le "$1.wav"
  echo "wrote $1.wav"
}

mk dbl_tight blip_noise_02  0.15 blip_silent_02
mk dbl_gap03 blip_noise_01  0.3  blip_breath_01
mk dbl_gap06 blip_noise_01  0.6  blip_breath_01
mk dbl_gap10 blip_silent_01 1.0  blip_noise_02
mk dbl_gap15 blip_breath_02 1.5  blip_breath_03
