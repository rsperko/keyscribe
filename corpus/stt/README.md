# STT benchmark — tiered recording guide

This is the **engine-accuracy** sub-corpus (WER / term recall / RTF). The shared recorder and ranker
live one level up (`corpus/record.sh`, `corpus/compare.sh`); see `corpus/README.md` for the overview.

**What's committed vs not:** `manifest.json` (prompts + ground truth + bias terms + tier/tags) and
this README are the committed, reproducible *kit*. The `*.wav` recordings and `results.json` are
**gitignored** — they're your own voice, supplied locally. Anyone can record their own corpus against
this manifest and get comparable numbers.

Read each `text` in `manifest.json` aloud, exactly as written, and save it as `<id>.wav` in this
folder (`corpus/record.sh` does this for you). `biasTerms` are the dictionary terms each clip
exercises (empty = a plain-accuracy clip).

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
bash corpus/record.sh --status              # per-tier recorded/total, records nothing
bash corpus/record.sh --tier T1             # record the remaining Tier 1 clips
bash corpus/record.sh --tier T2             # then T2, later, when you want ranking-grade numbers
bash corpus/record.sh                       # record everything still missing (all tiers)
bash corpus/record.sh --device :2 --tier T1 # pick a non-default mic
bash corpus/record.sh 14 c27 c82            # (re)record specific ids, overwriting them
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

## Compare engines

First build the app once (bundles the MLX metallib Qwen3 needs):

    ./make-app.sh release

Then score every installed engine over the clips you recorded and get a ranked report:

    bash corpus/compare.sh

`compare.sh` runs the benchmark, then prints engines sorted by biased WER with a bias-term recall,
speed (RTF), and install-size column, plus three picks: **best accuracy**, **lightest that stays
close** to the best, and **fastest**. Engines whose models you haven't installed are skipped —
install the ones you want from Settings → Speech Models first, or limit the set to avoid downloading
all of them:

    bash corpus/compare.sh --engines qwen3-asr-0.6b,parakeet,moonshine-base-en
    bash corpus/compare.sh --fuzzy      # also apply the post-STT fuzzy corrector before scoring
    bash corpus/compare.sh --raw        # raw per-clip transcripts, no scoring or ranking
    bash corpus/compare.sh --bin PATH   # score with a specific build instead of .build/release

Engine ids: `parakeet`, `parakeet-tdt-ctc-110m`, `whisper`, `whisper-small-en`, `apple`,
`qwen3-asr-0.6b`, `qwen3-asr-1.7b`, `moonshine-base-en`.

**Finding the smallest engine that works for you:** record T2, then run `compare.sh`. The
"lightest that stays close" pick is the engine with the smallest install whose `WER(bias)` and
`recall(bias)` are within a hair of the best — that is usually your answer, since RTF < 1.0 means
every engine is faster than real time anyway.

### Under the hood

`compare.sh` wraps the headless benchmark, which you can also run directly:

    .build/release/KeyScribe --benchmark corpus/stt [--engines …] [--fuzzy] [--raw]

It prints the per-engine table (WER unbiased vs biased, bias term recall, RTF) and writes
`results.json` here; `compare.sh` adds the ranking and recommendations on top of that file.
