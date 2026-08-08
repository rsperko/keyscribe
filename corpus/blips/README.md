# blips/ — no-speech admission corpus

Empty trigger presses versus genuine short utterances, both captured through the **real app trigger
path**. This is the regression gate for `SpeechPresenceGate`'s admission rule: the clips that must be
suppressed and the clips that must not be, in one manifest.

```bash
KeyScribe --vad-probe corpus/blips            # PASS/FAIL against checks.vad.presence; exit 1 on any miss
KeyScribe --vad-probe corpus/blips --chunks   # + per-clip probability vector, n>=threshold, longest run
```

## Why it exists

A press-and-release of the dictation trigger with nothing said used to reach the speech engine, which
answered with whatever it hallucinates on noise — for Qwen3-ASR 1.7B that is a Chinese filler (`哦。`,
`嗯。`) or an echoed dictionary term, pasted as a normal dictation. The gate admitted those takes
because it required only a **take-level max**: one 256 ms chunk over the threshold, anywhere.

Measured over this corpus, that is exactly what a stray press produces:

| Set | Duration | Chunks clearing 0.30 | maxP |
|---|---|---|---|
| 7 empty presses (`blip_*`) | 0.20–0.51 s | **1** (run 1) | 0.42–0.92 |
| `short_right_now`, shortest real take | 0.40 s | **2** (run 2) | 1.00 |
| 11 other short utterances | 0.70–2.85 s | **3–9** (run 3–5) | 1.00 |
| `corpus/stt` sentences, for reference | — | 6+ (run 2+) | 1.00 |

**Confidence does not separate the populations** — a breath scored 0.92, higher than several real
takes' weakest chunk. Duration does. Hence `minSpeechChunks = 2`.

`short_right_now` is the load-bearing clip: it is the shortest genuine utterance recorded and sits
exactly on the two-chunk minimum. Raising the minimum to 3 would reject real speech. Do not raise it
without recording shorter real takes first and showing they still clear it.

## Total count vs. longest consecutive run

Admission counts **total** clearing chunks, not the longest consecutive run. The `dbl_*` clips exist
to justify that, because the obvious worry is that a total count admits two unrelated noises in one
take (a press click and a release click) that a run rule would reject.

Measured, it does not work that way. Silero is contextual, so two blips separated by a real gap score
**one** clearing chunk between them, not two — `dbl_gap06` / `dbl_gap10` / `dbl_gap15` / `dbl_tight`
all read count 1, run 1, and both rules suppress them. The only derived clip that reaches two is
`dbl_gap03` (0.3 s gap), where the two blips merge into one contiguous region — and there the run is
2 as well, so a run rule admits it identically. Longest-run buys nothing on this corpus.

It also costs margin. `corpus/stt/c72` is real speech with **count 6 but longest run 2**: speech
fragments, and a run rule sits one dropout away from suppressing a legitimate six-chunk utterance.
`short_cancel_01` (2.85 s) shows the same split at count 9 / run 3.

`dbl_gap03` is a known residual gap — two noises close enough to merge are admitted by any rule in
this family. It carries **no** `checks.vad` expectation for that reason: the corpus does not assert
behavior that is merely the status quo. It is not a regression (the old take-level-max rule admitted
it too). Closing it needs a different signal than chunk counting.

## Clips

- `blip_*` — trigger pressed and released with nothing said; `text` is empty,
  `checks.vad.presence: "noSpeech"`. Three flavours: `silent` (still, no breath), `breath` (audible
  exhale or lip smack), `noise` (typing / room noise nearby).
- `short_*` — genuine one- or two-word dictations; `text` is what was spoken,
  `checks.vad.presence: "speech"`. These are the false-negative guard.
- `dbl_*` — **derived**, not recorded: two real `blip_*` clips concatenated with a silence gap, built
  by `gen.sh`. See the count-vs-run section above. They are `source: "human"` (the voice is real; only
  the arrangement is synthetic) and carry the `derived` tag — the same convention `silence-lead` uses
  for its gen-script clips.
- `clip_*` — **declared but NOT yet recorded.** Fast-release twins; see below.

## Fast-release twins (`clip_*`) — the open question

Every `short_*` clip was recorded deliberately, holding the trigger through the whole word. So the
population that would actually expose a **too-high** minimum is absent from this corpus by
construction: a real one-word dictation where the user releases the trigger early and clips the tail.
That is the shape a false negative takes in daily use, and nothing here measures it.

The ten `clip_*` entries declare that population. Each is the twin of the same-named `short_*` clip —
**same word, same voice, one variable: the release timing** — so the pair is directly comparable:

| record | against | asking |
|---|---|---|
| `clip_yes` … `clip_cancel`, `clip_right_now` | `short_yes` … `short_cancel`, `short_right_now` | how many clearing chunks does an early release cost? |

### How to record them

**Not with `record.sh`.** The variable being measured *is* the trigger release, and `record.sh` reads
a script into ffmpeg — it cannot produce a clipped take. These have to come through the real trigger,
the same way every other clip here did:

1. Set `[audio] keep_captures = true` in `settings.toml` (see the Provenance section below).
2. Dictate each word from the table, releasing the trigger **as early as you can** while still saying
   the whole word. Aim to feel like you cut it off.
3. Pull the WAVs out of `<support-dir>-captures/` and name them `clip_<word>.wav` here.
4. `python3 .claude/skills/keyscribe-corpus/scripts/verify-source.py corpus/blips/manifest.json`

### They deliberately carry no `checks.vad`

This is a **measurement, not an assertion**. Adding `presence: "speech"` up front would presume the
answer to the question the clips exist to ask — and if some of them then failed, that finding would
land as a hard preflight failure blocking `publish.sh` on an open research question. Same convention
`dbl_gap03` follows: the corpus does not assert behavior it has not measured.

Until they are recorded, `--vad-probe` reports them as `missing … skipping` and the gate still passes
on its 23 real expectations; `b-vad-gate` in preflight scopes its completeness check to
expectation-carrying clips for exactly this reason, so declaring them costs no coverage.

### What to do with the result

```bash
KeyScribe --vad-probe corpus/blips --chunks   # read the clearing count per clip
```

Compare each `clip_*` against its `short_*` twin, then:

- **All ≥ 2** → the minimum survives a real fast release. Add `checks.vad.presence: "speech"` to each
  and they become a permanent false-negative guard with actual margin behind it.
- **Any at 1** → `minSpeechChunks = 2` is too high for a clipped take. That is the finding. Do **not**
  quietly add the expectation; the rule needs to change (or admission needs a signal other than chunk
  count), and `corpus/blips` now holds the counter-example that proves it.

Either way, record the numbers in the table at the top of this README — it is the measured evidence
the minimum rests on, and right now that table has no fast-release row.

## Provenance

`source: "human:capture-archive"` — real recordings of a human voice, but pulled from the app's own
capture archive (`[audio] keep_captures` in `settings.toml`, archived under
`<support-dir>-captures/`) rather than `corpus/record.sh`. That path is the point: a blip only exists
as the audio the real trigger admits, including head-admission trimming and the engine's capture
sample rate, so it cannot be reproduced by reading a script into ffmpeg.

Consequence: these WAVs carry no `Lavf` encoder tag. `verify-source.py` classifies them by the
CoreAudio writer's `JUNK`-chunk + IEEE-float header instead; run it after adding clips.

```bash
python3 .claude/skills/keyscribe-corpus/scripts/verify-source.py corpus/blips/manifest.json
```

## Re-recording

The `*.wav` are gitignored (your own voice/mic/room); `manifest.json`, `gen.sh` and this README are
committed. To rebuild against your own setup: set `keep_captures = true` under `[audio]` in your
`settings.toml`, perform the presses described above, copy the archived WAVs in and relabel, then run
`bash corpus/blips/gen.sh` to rederive the `dbl_*` clips. Turn `keep_captures` back off afterwards —
it archives raw speech.

Until you do, `--vad-probe corpus/blips` **fails** on a fresh checkout rather than reporting a vacuous
pass: a clip that states an expectation but has no WAV is a failure, not a skip.
