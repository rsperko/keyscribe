# STT benchmark — recording guide

**What's committed vs not:** `manifest.json` (prompts + ground-truth + bias terms), `record.sh`, and
this README are the committed, reproducible *kit*. The `*.wav` recordings and `results.json` are
**gitignored** — they're your own voice, supplied locally. Anyone can record their own corpus against
this manifest and get comparable numbers.

Read each sentence in `manifest.json` aloud and save it as `<id>.wav` in this folder
(`01.wav`, `02.wav`, …). The `text` field is the ground truth, so just read it as written.
`biasTerms` are the dictionary terms each clip exercises — entries with empty `biasTerms`
measure plain accuracy; the rest measure whether recognition bias recovers the term.

Record naturally: your normal mic, your normal pace. A couple of clips in a slightly noisy
room are useful too (just re-record one or two with background sound).

## Recording with ffmpeg (mic → 16 kHz mono wav)

List input devices first:

    ffmpeg -f avfoundation -list_devices true -i ""

Find your mic's index (e.g. `:0`), then record one clip (Ctrl-C to stop after you finish reading):

    ffmpeg -f avfoundation -i ":0" -ac 1 -ar 16000 01.wav

Repeat per id. (First run may prompt for microphone permission for your terminal.)

Prefer a GUI? Voice Memos or QuickTime → record → export, then convert:

    afconvert in.m4a -f WAVE -d LEI16@16000 -c 1 01.wav

## Run the benchmark

From the repo root, build the release app once (bundles the MLX metallib Qwen3 needs):

    ./make-app.sh release

Then run the headless benchmark over this folder:

    .build/release/KeyScribe --benchmark benchmark

It prints a per-engine table (WER unbiased vs biased, bias term recall, RTF) and writes
`results.json` here. Engines whose models you haven't installed in the app are skipped —
install the ones you want to compare from Settings → Speech Models first.

Limit to specific engines (avoids downloading all six ~6 GB of models) with `--engines`:

    .build/release/KeyScribe --benchmark benchmark --engines qwen3-asr-0.6b,whisper,parakeet

Engine ids: `parakeet`, `parakeet-tdt-ctc-110m`, `whisper`, `apple`, `qwen3-asr-0.6b`, `qwen3-asr-1.7b`.
