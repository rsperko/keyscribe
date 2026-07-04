#!/usr/bin/env bash
# Provision the TTS toolchain and generate the synthetic multi-voice "scratch that" corpus.
# Idempotent: creates a local venv (corpus/voices/.ttsenv, override with KEYSCRIBE_TTS_VENV),
# installs mlx-audio + misaki, ensures Homebrew espeak-ng, then runs gen_corpus.py. See README.md.
#
#   bash corpus/voices/gen-corpus.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v afconvert >/dev/null || { echo "afconvert missing (macOS only)"; exit 1; }

# espeak-ng is required by Kokoro's G2P (misaki). Homebrew install; kokoro_launch.py finds it.
if ! brew list espeak-ng >/dev/null 2>&1; then
  echo "installing espeak-ng via Homebrew…"
  brew install espeak-ng
fi

VENV="${KEYSCRIBE_TTS_VENV:-$PWD/.ttsenv}"
if [ ! -x "$VENV/bin/python" ]; then
  PY="$(command -v python3.11 || command -v python3.12 || command -v python3)"
  echo "creating venv at $VENV using $PY (3.11/3.12 recommended; 3.14 lacks some wheels)…"
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q mlx-audio "misaki[en]" num2words

"$VENV/bin/python" gen_corpus.py

echo
echo "Now run the raw STT dump + analysis from the repo root:"
echo "  .build/release/KeyScribe --benchmark corpus/voices --raw > /tmp/raw.txt 2>/dev/null"
echo "  corpus/voices/.ttsenv/bin/python corpus/voices/analyze.py /tmp/raw.txt"
