# Bias corpus — recognition-bias stress + engine onboarding

The **recognition-bias** sub-corpus: entity-dense clips whose whole point is to separate an engine's
raw acoustics from what a **bias list** recovers. Where `stt/` measures general accuracy on your own
voice, `bias/` hammers the one axis that decides KeyScribe engine quality — biased vs unbiased WER and
bias-term recall — and doubles as the **streaming-vs-batch** and **new-engine onboarding** fixture.

Derived from **[ContextASR-Bench](https://huggingface.co/datasets/MrSupW/ContextASR-Bench)** (MIT):
zero-shot-TTS English speech, each clip annotated with the named entities it contains. Those entities
*are* the bias terms — no hand-authoring. `build.py` picks the entries that most exercise bias (dense,
hard proper-nouns / acronyms / spelled-out alphanumerics like `"I S D N protocol stack"`) spread across
domain families so the kit is not all one vocabulary.

**What's committed vs not:** `manifest.json`, `build.py`, `fetch.sh`, and this README are the committed
kit. The `*.wav` clips, the fetched `shard.tar`, and the metadata `.jsonl` are **gitignored** (bulky /
redistributable upstream) — reproduce them locally with `fetch.sh` + `build.py`.

## Why these clips (design)

- **Every clip is 26–77 s**, well past the 4 s streaming threshold, so each one opens a live streaming
  session *and* runs as batch — one corpus covers both paths.
- **Provenance:** audio is ContextASR zero-shot TTS → `source: "tts:contextasr"` (never `human`; passes
  `verify-source.py` because there is no ffmpeg `Lavf` tag). Clips are 16 kHz mono PCM, extracted as-is.
- **Caveat — this is TTS, not your voice, and it is long-form.** It measures *lexical* bias recovery,
  not your mic/room acoustics or short-utterance dictation. It does **not** replace the real-voice
  `stt/` corpus or the `commands/` pipeline checks — it complements them.

## Reproduce the corpus

```bash
bash corpus/bias/fetch.sh                       # ~1.87 GB smallest Speech/English shard + metadata
python3 corpus/bias/build.py \
    --shard corpus/bias/shard.tar \
    --meta  corpus/bias/ContextASR-Speech_English.jsonl   # writes bx01..bxNN.wav + manifest.json
```

`build.py` is deterministic (rank by bias-impact, diversity caps per domain family) — re-running
reselects the same clips. Tune with `--n`, `--family-cap`, `--domain-cap`. Each clip's origin id is
recorded in its `tags` as `contextasr:<uniq_id>` for traceability.

## Run it

```bash
# biased vs unbiased WER + bias-term recall (batch) — any engine
.build/debug/KeyScribe --benchmark corpus/bias --engines parakeet-tdt-ctc-110m
# literal per-clip output (diff bias vs unbias by eye)
.build/debug/KeyScribe --benchmark corpus/bias --engines parakeet-tdt-ctc-110m --raw
# streaming↔batch parity — only streaming-capable engines (today: apple)
.build/debug/KeyScribe --benchmark corpus/bias --engines apple --streaming
.build/debug/KeyScribe --benchmark corpus/bias --engines apple --streaming --raw
```

`--streaming` drives the real `StreamingDictationDriver` at **realtime cadence** (the same feed a live
mic produces), so a full 20-clip run streams in ~realtime (minutes) by design — that is what keeps the
session's input queue drained exactly as the app does. Set `KEYSCRIBE_STREAM_SPEEDUP=N` to feed N× faster
for quick iteration; `>1` may trip the driver's backpressure fallback on a slower engine (reported as
`fellBack`), which is itself a realistic signal. A clip that falls back is scored as batch (what the user
would get). `KEYSCRIBE_BENCH_VERBOSE=1` prints per-clip batch-vs-stream text.

Use `KeyScribeDev.app/Contents/MacOS/KeyScribe` instead of the raw `.build` binary for the Qwen MLX
engines (the raw binary lacks the bundled metallib — see the corpus skill gotchas). The benchmark
writes `results.json` here (gitignored). Engine ids: `parakeet`, `parakeet-tdt-ctc-110m`, `whisper`,
`whisper-small-en`, `apple`, `qwen3-asr-0.6b`, `qwen3-asr-1.7b`, `moonshine-base-en`.

## Onboarding a new engine — the standing checklist

When a new STT model is added to the catalog, run it through this kit before shipping:

1. **Bias, batch** — `--benchmark corpus/bias --engines <id>`. Expect biased WER ≤ unbiased and
   bias-term recall to jump with bias on. A bias-capable engine that shows no biased/unbiased gap here
   is not actually applying bias — investigate before shipping.
2. **Bias, streaming** — add `--streaming`. Confirm the streamed final is close to batch; a large gap
   means the streaming session is dropping context the batch path keeps.
3. **No-speech sweep, both paths** — the AGENTS.md invariant: generate silence/hiss clips and run
   `--raw` (batch) *and* `--streaming --raw`, checking for hallucinated markers. Bias content does not
   cover silence — keep that sweep separate.
4. **Commands** — `--commands-check corpus/commands` for the no-LLM pipeline (unaffected by bias, but
   part of "does this engine behave").

A new engine that clears bias (1–2), silence (3), and commands (4) has been exercised on every path
KeyScribe drives.
