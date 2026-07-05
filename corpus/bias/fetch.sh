#!/usr/bin/env bash
# Fetch the ContextASR-Bench audio shard used to build the bias sub-corpus.
#
# ContextASR-Bench (MrSupW/ContextASR-Bench, MIT) packs its Speech/English audio into 8 tar
# shards with no per-file access and no id->shard map. We build the corpus from the SMALLEST
# shard (_8, ~1.87 GB) so the download is bounded; build.py selects the best entries within it.
# The wavs themselves are gitignored (like all corpus audio) — only the manifest + this script
# are committed, so anyone can reproduce the same clips.
set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")" && pwd)/shard.tar}"
URL="https://huggingface.co/datasets/MrSupW/ContextASR-Bench/resolve/main/audio/ContextASR-Speech/English/ContextASR-Speech_English_8.tar"
META_URL="https://huggingface.co/datasets/MrSupW/ContextASR-Bench/resolve/main/ContextASR-Speech_English.jsonl"
METADEST="$(dirname "$DEST")/ContextASR-Speech_English.jsonl"

echo "→ metadata  → $METADEST"
curl -fSL "$META_URL" -o "$METADEST"
echo "→ audio tar → $DEST  (~1.87 GB, be patient)"
curl -fSL "$URL" -o "$DEST"
echo "done. next: python3 corpus/bias/build.py --shard '$DEST' --meta '$METADEST'"
