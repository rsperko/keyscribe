# silence-lead — leading-silence empty-transcript regression set

Parakeet can return an **empty transcript** when substantial silence precedes the speech in a short
take, even though the take contains clear speech (proven on a real recording; trimming the leading
silence recovered the full transcript). This sub-corpus keeps that failure watched: human stt clips
with a fixed leading span prepended, replayed through the real engines.

Plan and product contract for the recovery: `agent_notes/parakeet_silent_bug_recovery/README.md`.

**The load-bearing clip is `lead_repro1.wav`** — a real failing capture (1.536 s: ~0.9 s quiet
webcam lead-in + ~0.6 s speech). On it, Parakeet TDT v3 returns an empty transcript while every
other engine returns text and VAD reads speech at maxP=1.000; trimming the leading silence recovers
text. **It is local-only and NOT in a fresh checkout** — every WAV here is gitignored (only
`manifest.json`, `gen.sh`, and this README are committed), and it cannot be regenerated, so nothing
in this sub-corpus currently gives another machine a working reproduction of the failure. See
"Known limitation" below. Full verification detail:
`agent_notes/parakeet_silent_bug_recovery/README.md` §Validation.

Root cause is **unconfirmed**. NVIDIA-NeMo/Speech #15757 is related evidence — `parakeet-tdt-0.6b-v3`
returning empty when 400 ms of silence is *appended* to speech, which the reporter (not a maintainer)
attributes to the tail shifting the prefix's normalized log-mel features. That is **trailing** silence;
this capture is **leading**. Read it as "TDT v3's feature normalization is silence-sensitive", not as a
confirmed diagnosis of this clip.

**Known limitation (2026-07-16): no synthetic construction reproduces the bug.** Parakeet
(both models) transcribed every derived clip cleanly — including scratch probes with 20/30/60 s
digital-silence leads, a 20 s room-tone lead, digital silence prepended to the repro's own speech,
and even the repro's real lead audio doubled — while VAD admitted all clips as speech
(`--vad-probe`: maxP=1.000 across the set). The collapse is knife-edge specific to the exact
original buffer. The derived clips therefore serve as (a) proof that VAD admits long-lead takes
(the recovery's eligibility precondition), and (b) a tripwire should an engine or dependency bump
regress on synthetic leads — but only the real repro take exercises the failure. Treat
`lead_repro1.wav` as an irreplaceable local-only observation: it is gitignored like all corpus audio,
it cannot be regenerated, and it is the only known instance of the collapse — keep the original safe
outside the repo.

**Consequence — this corpus does not currently ship a reproduction of the bug.** A fresh checkout gets
the manifest and `gen.sh`, whose derived clips all pass; the failing input is never distributed. Note
what is and isn't machine-bound: the failure itself occurred and was verified on a separate machine
from the one that verified the recovery, so it is a real TDT v3 behavior rather than a local audio
artifact — it is the *clip* that doesn't travel, not the bug.
**Finding a reproducible, distributable regression case is open future work** — either a synthetic
construction that actually collapses TDT v3 (none found so far), or a shareable recording that does.
Until then the recovery's regression safety net is its unit tests, not this corpus.

## Clips

Every derived clip is a committed human `corpus/stt` recording with a lead prepended — the clip id
encodes the derivation:

- `lead_<base>_<N>s` — N seconds of digital silence, then `stt/<base>.wav`
- `lead_<base>_hiss<N>s` — N seconds of faint hiss (a=0.02, the quiet-room level from the engine
  silence sweep), then `stt/<base>.wav`

`source` stays `human`: the speech is the original human recording, unmodified — only silence/noise
is prepended. The `derived-silence` tag marks these as generated; regenerate them any time with:

```bash
bash corpus/silence-lead/gen.sh
```

A clip id that doesn't match the pattern is a **real recording** (e.g. a captured repro take) and is
never touched by `gen.sh`.

## Adding a real repro take

A WAV captured from an actual failing dictation is worth more than any synthetic variant
(`lead_repro1` is the first; number subsequent takes `lead_repro2`, …). To add one:

1. Copy the wav in as `lead_repro<N>.wav` (16 kHz mono; convert with
   `ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le lead_repro1.wav` if needed).
2. Add its manifest row: `id`, `file`, the exact `text` spoken, `source: "human"`, and a
   `tags: ["repro"]` marker.

## Replay

```bash
# Which engines return text vs nothing as the lead grows (RAW lines show literal output per clip):
./KeyScribeDev.app/Contents/MacOS/KeyScribe --benchmark corpus/silence-lead --raw

# Just Parakeet (the engine with the proven failure):
./KeyScribeDev.app/Contents/MacOS/KeyScribe --benchmark corpus/silence-lead --engines parakeet,parakeet-tdt-ctc-110m --raw

# Confirm VAD still admits every clip as speech (the recovery's eligibility precondition):
./KeyScribeDev.app/Contents/MacOS/KeyScribe --vad-probe corpus/silence-lead
```

An empty RAW output on any clip here is the bug: VAD reads these takes as speech, so a silent
engine result must surface as the recovery path (or its named-model error), never as
`No speech detected`.

Note the benchmark exercises the **engine layer only** — it calls `transcribe` directly, so it
demonstrates the raw failure and will keep doing so even after the controller-level recovery ships.
The recovery itself (trim + one retry) is covered by unit tests over the same trim math; this corpus
is the ground truth those tests are calibrated against.
