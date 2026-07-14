# STT benchmark — reference numbers

> **Read this first.** These numbers are from **one person's voice, in a quiet room, on a
> built-in MacBook microphone**. Speech recognition is extremely speaker-, accent-, mic-, and
> room-dependent — your ranking *will* differ, and the top models here are close enough that the
> order flips easily. Treat this as a sanity check and a reproduction baseline, **not** a
> leaderboard. To get numbers that reflect *your* setup, record your own corpus — see
> [`corpus/stt/README.md`](../../corpus/stt/README.md).

**Corpus:** 107 clips (the committed `manifest.json` corpus, Tiers 1–3).
**Recorded:** 2026-06-30, single speaker, quiet room, built-in mic, normal pace.
**Metrics:** WER = word error rate (lower is better); recall = dictionary-term recall (higher is
better); RTF = real-time factor (lower is faster; < 1.0 means faster than real time).
Numbers are **as shipped** — the dictionary active with default settings (after-transcription recovery
on every engine, plus recognition bias on the Whisper and Qwen3 models). "Recall — no dictionary" is the
raw engine with an empty dictionary, so the two recall columns show the dictionary's total lift.
Apple Speech is the macOS system model and appears in KeyScribe only on macOS 26+.

> These results use recognition-time dictionary bias only for the **Whisper and Qwen3** models.
> Parakeet and Apple bias were removed because they could substitute dictionary terms that were never
> spoken; see the [decision record](../../agent_notes/decisions/recognition_bias.md). The dictionary still
> lifts recall on **every** engine via after-transcription recovery; on Whisper and Qwen3 recognition
> bias lifts it further. So the recall gap between the two columns below is the dictionary's whole effect,
> and it is largest on the bias-capable models.

| Model | WER (as shipped) | Recall — with dictionary | Recall — no dictionary | RTF | Download |
|---|---|---|---|---|---|
| Whisper Large v3 Turbo | 5.7% | 0.96 | 0.81 | 0.119 | 632 MB |
| Qwen3-ASR 1.7B | 5.8% | 0.96 | 0.84 | 0.040 | 2.0 GB |
| Whisper Small (English) | 6.0% | 0.97 | 0.78 | 0.063 | 217 MB |
| Parakeet TDT v3 (default) | 7.1% | 0.89 | 0.77 | 0.014 | 480 MB |
| Qwen3-ASR 0.6B | 8.3% | 0.96 | 0.78 | 0.014 | 1.5 GB |
| Parakeet TDT-CTC 110M | 9.8% | 0.85 | 0.69 | 0.008 | 330 MB |
| Apple Speech | 12.8% | 0.62 | 0.53 | 0.032 | managed |
| Moonshine Base (English) | 14.9% | 0.74 | 0.66 | 0.024 | 141 MB |

## What to read into this (and what not to)

- **The top three are a wash.** 5.7 / 5.8 / 6.0% biased WER is well inside the noise of a
  single-speaker corpus. Don't pick between them on these numbers alone.
- **The dictionary helps on every engine.** The Whisper and Qwen3 models steer recognition toward
  your terms as they listen; Parakeet, Apple, and Moonshine do not, and reach the dictionary through
  after-transcription recovery, which runs by default on all engines. So a dictionary term is never a
  no-op — the mechanism just differs by model.
- **Everything is faster than real time.** Every RTF is well under 1.0, so on this corpus speed is
  rarely the deciding factor — footprint and accuracy are.
- **The default isn't the most accurate, by design.** Parakeet TDT-CTC 110M is the recommended
  English default because it is compact, fast, and low-memory — not because it tops this table.
  "Recommended" means *sensible starting point*, not *highest score*.
- **The lightest model that stays close to the best is usually your answer.** Record Tier 2, run
  `bash corpus/compare.sh`, and read its "lightest that stays close" pick.

## Reproduce on your own voice

```bash
bash corpus/record.sh --tier T2   # record the ranking-grade tier (record more later for T3 precision)
./make-app.sh release                # bundles the MLX metallib Qwen3 needs
bash corpus/compare.sh            # ranked report over the engines you have installed
```

`compare.sh` writes the raw per-engine numbers to `corpus/stt/results.json` (gitignored — it's
your voice) and prints a ranking plus best-accuracy / lightest-that-stays-close / fastest picks.
Full methodology, corpus tiers, and recording guidance are in
[`corpus/stt/README.md`](../../corpus/stt/README.md).
