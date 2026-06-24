# STT benchmark — tiered recording guide

**What's committed vs not:** `manifest.json` (prompts + ground truth + bias terms + tier/tags),
`record.sh`, and this README are the committed, reproducible *kit*. The `*.wav` recordings and
`results.json` are **gitignored** — they're your own voice, supplied locally. Anyone can record their
own corpus against this manifest and get comparable numbers.

Read each `text` in `manifest.json` aloud, exactly as written, and save it as `<id>.wav` in this folder.
`biasTerms` are the dictionary terms each clip exercises (empty = a plain-accuracy clip).

## Corpus design — tiers

The corpus is stratified and scaled by **word count**, not clip count (WER precision needs error
*events*, which need words). Record in tiers; each tier is a superset you grow into. See
`agent_notes/evaluate_stt_models_with_corpus/keyscribe-stt-corpus.md` for the full rationale.

| Tier | Purpose | When it's enough |
|------|---------|------------------|
| **T1** | Smoke / fast iteration. Catches gross regressions. | Rough engine ranking, sanity. |
| **T2** | Reliable model **ranking**; trustworthy WER down to ~2%. | The real target for picking an engine. |
| **T3** | Long + stress passages for believable absolute WER < ~1.5%. | Final precision pass. |

Each entry carries `tier`, `tags` (strata: `cmd` `casual` `status` `tech` `proj` `names` `punct`
`long` `stress`), and `condition` (`normal` by default). The 16 original clips (`01`–`16`) are kept as
tagged T1 entries; the corpus adds `c01`–`c91`.

> `c82` is the exact same sentence as legacy `12`, so `c82.wav` is pre-seeded as a copy of `12.wav` —
> no need to record it.

## Recording

The recorder is **resumable**: stop with Ctrl-C any time and re-run — already-recorded clips are
skipped. Record a long corpus over several sittings, tier by tier.

```bash
bash benchmark/record.sh --status              # per-tier recorded/total, records nothing
bash benchmark/record.sh --tier T1             # record the remaining Tier 1 clips
bash benchmark/record.sh --tier T2             # then T2, later, when you want ranking-grade numbers
bash benchmark/record.sh                       # record everything still missing (all tiers)
bash benchmark/record.sh --device :2 --tier T1 # pick a non-default mic
bash benchmark/record.sh 14 c27 c82            # (re)record specific ids, overwriting them
```

For each prompt it shows the line + its `tier · tags`, waits for Enter to start, records mic →
`<id>.wav` (16 kHz mono via ffmpeg), and waits for Enter to stop. A clip under 4 KB is flagged as a
failed recording (usually missing mic permission or a wrong device index).

Find your mic's avfoundation index first:

    ffmpeg -f avfoundation -list_devices true -i ""

Record naturally: your normal mic, your normal pace. For a robustness slice, re-record a stratified
~15–20% subset in a noisy room / at a rushed pace / softer, and note it (the corpus doc lists good
candidates and the `noisy`/`fast`/`soft` conditions).

Prefer a GUI? Voice Memos or QuickTime → record → export, then convert:

    afconvert in.m4a -f WAVE -d LEI16@16000 -c 1 c27.wav

## Run the benchmark

From the repo root, build the release app once (bundles the MLX metallib Qwen3 needs):

    ./make-app.sh release

Then run the headless benchmark over this folder:

    .build/release/KeyScribe --benchmark benchmark

It prints a per-engine table (WER unbiased vs biased, bias term recall, RTF) and writes
`results.json` here. Engines whose models you haven't installed are skipped — install the ones you
want to compare from Settings → Speech Models first, or limit with `--engines` to avoid downloading
all of them:

    .build/release/KeyScribe --benchmark benchmark --engines qwen3-asr-0.6b,parakeet,moonshine

Engine ids: `parakeet`, `parakeet-tdt-ctc-110m`, `whisper`, `apple`, `qwen3-asr-0.6b`,
`qwen3-asr-1.7b`, `moonshine-base-en`.

**Finding the smallest engine that works for you:** record T2, then compare the smaller engines
(`qwen3-asr-0.6b`, `parakeet-tdt-ctc-110m`, `moonshine-base-en`) against the larger ones on
`WER(bias)`, `recall(bias)`, and `RTF`. The smallest engine whose biased WER and term recall stay
close to the best is your pick — RTF shows it's fast enough, and it's the lightest install.
