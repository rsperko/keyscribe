# STT benchmark — reference numbers

> **Read this first.** These numbers are from **one person's voice, in a quiet room, on a
> built-in MacBook microphone**. Speech recognition is extremely speaker-, accent-, mic-, and
> room-dependent — your ranking *will* differ, and the top models here are close enough that the
> order flips easily. Treat this as a sanity check and a reproduction baseline, **not** a
> leaderboard. To get numbers that reflect *your* setup, record your own corpus — see
> [`corpus/stt/README.md`](../../corpus/stt/README.md).

**Corpus:** 107 clips (the committed `manifest.json` corpus, Tiers 1–3).
**Recorded:** 2026-06-30, single speaker, quiet room, built-in mic, normal pace.
**Metrics:** WER = word error rate (lower is better); recall = bias-term recall (higher is
better); RTF = real-time factor (lower is faster; < 1.0 means faster than real time).
"bias" columns are with the dictionary active; "unbiased" is plain accuracy.
Apple Speech is the macOS system model and appears in KeyScribe only on macOS 26+.

| Model | WER (bias) | WER (unbiased) | Recall (bias) | RTF | Download |
|---|---|---|---|---|---|
| Whisper Large v3 Turbo | 5.7% | 6.9% | 0.96 | 0.114 | 632 MB |
| Qwen3-ASR 1.7B | 5.8% | 6.9% | 0.94 | 0.037 | 2.0 GB |
| Whisper Small (English) | 6.0% | 7.7% | 0.95 | 0.061 | 217 MB |
| Parakeet TDT v3 | 7.4% | 8.2% | 0.90 | 0.045 | 1.8 GB |
| Qwen3-ASR 0.6B | 8.4% | 10.0% | 0.93 | 0.014 | 1.5 GB |
| Parakeet TDT-CTC 110M (default) | 9.3% | 11.5% | 0.93 | 0.016 | 440 MB |
| Apple Speech | 12.2% | 13.5% | 0.74 | 0.031 | managed |
| Moonshine Base (English) | 15.5% | 14.6% | 0.66 | 0.019 | 141 MB |

## What to read into this (and what not to)

- **The top three are a wash.** 5.7 / 5.8 / 6.0% biased WER is well inside the noise of a
  single-speaker corpus. Don't pick between them on these numbers alone.
- **Bias is decisive for dictionary terms.** Every bias-capable engine gains real recall from the
  dictionary. Moonshine has **no on-device recognition bias** (its recall doesn't move), so it
  leans on post-STT dictionary recovery instead.
- **Everything is faster than real time.** Every RTF is well under 1.0, so on this corpus speed is
  rarely the deciding factor — footprint and accuracy are.
- **The default isn't the most accurate, by design.** Parakeet TDT-CTC 110M is the recommended
  default because it's small (440 MB), fast, English-first, and good enough out of the box — not
  because it tops the table. "Recommended" means *sensible default*, not *highest score*.
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
