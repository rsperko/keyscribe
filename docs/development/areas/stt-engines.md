# Speech-to-text engines

Read before adding or changing a speech model, an engine adapter, the no-speech gate, the empty-transcript recovery, recognition bias, or streaming transcription.

## Platform facts

- **STT (Parakeet/FluidAudio):** reload-from-cache ~0.13s, transcribe 74–90ms, resident
  ~27–38MB on short speech. Eviction is nearly free. API:
  ```swift
  import FluidAudio
  let models = try await AsrModels.downloadAndLoad(version: .v3)
  let manager = AsrManager(config: .default)
  try await manager.loadModels(models)
  var decoderState = try TdtDecoderState()
  let result = try await manager.transcribe(url, decoderState: &decoderState)  // result.text
  ```
- **macOS 27 may require an entitlement for BACKGROUND Neural Engine use — UNMEASURED, do not "fix"
  it blind.** Apple ships `com.apple.developer.background-tasks.continued-processing.inference`
  ("Background Inference"), listed **iOS/macOS 27.0+ (Beta)**. Its Discussion says the system requires
  it for **any** Neural Engine access while the app is in the background, *regardless of* a continued
  background task — and that second sentence is the only part that can apply to macOS, since
  `BGContinuedProcessingTask` does not exist there (the sibling `…continued-processing.gpu`
  entitlement is iOS-only, which is why this is easy to dismiss as inapplicable).
  **Why KeyScribe is exposed:** it is `LSUIElement` and by construction dictates into *another* app,
  so it is essentially never frontmost; Parakeet (both TDT and Unified) and the Silero VAD run
  `.cpuAndNeuralEngine` by FluidAudio default, and Qwen3's CoreML encoder is `.all`. (Whisper is
  already `.cpuAndGPU`, but for load-time reasons — `WhisperEngine.swift` — not entitlements.)
  **What is NOT known** (searched 2026-09-09, no evidence either way — do not invent an answer):
  whether an actively hotkey-driven menu-bar agent counts as "background" at all; whether the
  capability is approval-gated; whether a Developer ID (non-App-Store) app can carry it. Adding the
  key speculatively is NOT free: a `com.apple.developer.*` entitlement can require an embedded
  provisioning profile, which `release.sh` does not produce — that risks AMFI killing the app at
  launch, which is the same class of failure `make-app.sh` already documents for dev signing.
  **How to actually measure it** (cannot be done on macOS 26, and CANNOT be done with the dev build —
  the teamless self-signed "KeyScribe Local" cert cannot authorize such an entitlement):
  1. macOS 27 beta on a spare volume; build via `release.sh` (Developer ID).
  2. Dictate while KeyScribe is NOT frontmost (its normal state) and sample
     `sudo powermetrics --samplers ane_power`.
  3. `.build/checkouts/FluidAudio/Scripts/ane_profile.swift` reports the compute-unit **plan** only —
     it will still say ANE even if the runtime is denied, so the power trace is the ground truth.
  4. Silent-fallback signature: ANE power at zero **plus** a latency regression at unchanged WER.
  **One macOS 27 Neural Engine failure IS measured, and it is a different mechanism from the entitlement
  question above — do not fold them together.** On macOS 27.0.1 (2026-10-07) Parakeet TDT-CTC 110M on
  FluidAudio's default `.cpuAndNeuralEngine` loads without error and decodes every clip to blank (100% WER,
  1/35 `--commands-check` against a 28 baseline) while the ANE compiler logs `kernel width and height
  should be multiple of 8 for large kernel but are 512 and 1` — 512 is that model's encoder width, and it is
  the only Parakeet whose preprocessor+encoder is one fused model on the ANE. Every other engine on the ANE
  was unaffected, and the v0.8.0 binary that passed preflight on macOS 26.6.2 fails identically on 27.0.1.
  `ParakeetEngine.modelConfiguration(for:)` pins that one model to `.cpuAndGPU`, which restores its baseline
  exactly. A silent blank decode is precisely the failure shape the release gate exists for — it shipped in
  0.8.0 only because preflight had never run on macOS 27.
  **Two gaps this exposes regardless of macOS 27:** `preflight.sh`'s `a-entitlements` greps only for
  the literal `com.apple.security`, so it cannot see a missing or malformed `com.apple.developer.*`
  key; and **no preflight gate measures latency/RTF** — `b-benchmark` gates WER only, and an ANE→CPU
  fallback moves latency, not accuracy, so it would ship unnoticed.

## STT engines

Every shipped model is one entry in `SpeechModelCatalog.all`, with in-app download/install; its family
is an `EngineKind` and its bias capability is `supportsRecognitionBias`. **Read the catalog for the
current list — never restate it here.** Where a model biases at all, the mechanism is engine-family
policy: Qwen3 uses native context, Whisper uses decode-time prompt tokens. `supportsRecognitionBias`
is the source of truth for which models bias; do not restate that roster here either. The dictionary still prefers a user's spellings on **every**
engine via after-transcription recovery (`FuzzyStage`), which now runs whenever the mode's merged
dictionary is non-empty — no per-engine toggle. Engines are
wired through a single **`EngineRegistry`** descriptor list (catalog ↔ constructor) that the
provider, download path, install reconcile/delete, and the benchmark all derive from — adding an
engine is one descriptor + one catalog entry. **Parakeet Unified is the one exception to "one
descriptor + one construct case" being the whole story**: `AsrModelVersion` has no Unified case, so it
is reached through a separate `UnifiedAsrManager` and therefore a separate adapter
(`ParakeetUnifiedEngine`) under the same `.parakeet` kind. Two traps live there — its `loadModels(to:)`
takes the **base** models dir (the SDK appends the bundle name itself, the opposite of
`AsrModels.downloadAndLoad(to:)`), and it is the **only Parakeet that emits punctuation and
capitalization**, which is net-neutral on `--commands-check` (measured: it fixes `np_period`, which TDT
v3 fails for lack of a period, and breaks `sc_cb`; both engines land 30/35). `load(progress:)` is on the `SpeechEngine` protocol;
each engine owns its install footprint (`installDirNames` / `installState`); audio decode is shared
(`AudioDecoder`).

**The Apple entry is one catalog entry running one of two Apple models**, resolved once per engine load by
the pure `AppleSpeechModelChoice`: **Apple Speech** (`SpeechTranscriber`, Apple's current on-device model)
wherever `SpeechTranscriber.isAvailable` and the locale is supported, else **Apple Dictation**
(`DictationTranscriber`, Apple's earlier dictation model — broader Mac/language coverage, and it applies
keyboard-dictation commands to the transcript itself, with no API option to stop it). The fallback is
automatic, and Settings says which one is in play and why. **Map the locale through each model's own
`supportedLocale(equivalentTo:)`, then require the result to be in that model's `supportedLocales`**
(`AppleSpeechModelChoice.coveredLocale`). The mapping does the regional remapping (`en_150` → `en_US`,
`zh_Hant_TW` → `zh_TW`) but is not a support check: on macOS 26.6 it returns `nl_NL` for `SpeechTranscriber`
though that model does not list Dutch. Trusting the mapping alone sent Dutch, Polish, Russian and Swedish
Macs to a model that cannot run them instead of to Apple Dictation: the asset install then fails
(`transcription.nl asset unavailable after attempted download`), and skipping the install makes
transcription fail with a misleading "Audio format is not supported" (as measured, 2026-09-26). A language neither covers (`is_IS`)
resolves to no model at all, which must refuse to load rather than claim Apple Dictation. **A failed Apple
Speech download also falls back** (`AppleSpeechModelChoice.afterSpeechFailedToLoad`): an upgraded user
whose Apple Dictation worked yesterday must not lose dictation because they are offline on the first load.
`AppleEngine` retries the Apple Speech download in the background (at the fallback and at each later
dictation's prewarm, one attempt in flight) and switches on success; Settings and the benchmark's
`· apple:` line read the live fallback, so the benchmark loads the engine before announcing. Do not split it into two entries: nobody
should choose the older model where the newer one runs. `DictationTranscriber` was originally chosen
only because it honored `contextualStrings`; that reason left with Apple recognition bias. **Every Apple
measurement must name the model that produced it** — `--apple-model dictation` (or
`KEYSCRIBE_APPLE_MODEL`) forces the fallback on a Mac that would never reach it, and each benchmark /
commands-check run prints `· apple: Using …` to stderr.

A dev **STT benchmark** (`KeyScribe --benchmark <dir> [--engines …]`, runner + pure scoring in
KeyScribeKit) measures WER (biased vs unbiased) / term recall / RTF over recorded clips. On a
107-clip single-voice corpus the top engines (Whisper Large v3 Turbo, Qwen3-ASR 1.7B, Whisper
Small) cluster around 5.7–6.0% biased WER; Apple Speech measured 8.7% and its Apple Dictation
fallback 12.6% (as measured 2026-09-25). These numbers are
speaker/mic/room dependent — reference table + caveats in
`docs/reference/stt_benchmarks.md`, reproduction in `corpus/stt/README.md`. The shipped list order is
**recommended-first, grouped by engine family** (catalog order in `SpeechModelCatalog.all`), not
benchmark rank — a single-voice ranking can't carry that authority and would fight the
"Recommended" badge on the default.

**Every model carries measured accuracy and speed plus a lifecycle stage, all catalog data.** Each entry
stores its no-dictionary average WER and real-time factor; `accuracy` (`SpeechAccuracy`) and `speed`
(`SpeechSpeed`) are computed from them relative to the best offered model, under the rule in
`docs/reference/stt_benchmarks.md` ("Accuracy and speed labels") — re-measure when a model is added or an
engine dependency moves, never edit a label by feel. `isLegacy` is the deprecation path: a legacy model keeps working but is
not offered at first run, trails the catalog, and shows a "being phased out" advisory naming the
recommended model; no sooner than one release later it is **retired** — removed from `all` and added to
`retiredDisplayNames`, which moves its users to a usable model with a notice. Never retire a model that was
not legacy in a shipped release, and never switch a user off a legacy model automatically.

## Silence / no-speech behavior — exercise every new model

**First line of defense: the audio-side no-speech gate.** A finished take runs once through Silero VAD
(`SpeechPresenceDetector` adapter over FluidAudio's `VadManager`; verdict logic in the pure
`SpeechPresenceGate`, KeyScribeKit) BEFORE transcription — `DictationController.presenceReading`, at the
commit call site after `finishDraining()` and before `finalizeStreamingIfActive`. Admission is a minimum
speech **duration**, not a take-level max: fewer than `minSpeechChunks` (2) of the 256 ms chunks clearing
probability `0.30` is `.noSpeech` (a digital-silence peak short-circuits without even invoking the model),
and the dictation is suppressed with the same `.noSpeech` UX as an empty transcript — nothing is
transcribed or pasted. **The two-chunk minimum is load-bearing and confidence cannot replace it**: a stray
trigger press puts exactly ONE hot chunk in front of the model (a breath, a lip smack, the key itself) and
those score as high as **0.92** — higher than the weakest chunk of many real takes — so any single-chunk
admission rule, at any confidence, readmits the whole bug. See `corpus/blips` for the measured
populations and the shortest real take that pins the minimum at 2. An empty probability vector is
`.noSpeech`, NOT fail-open: the detector returns early with `modelUsed: false` whenever the model could
not run, so reaching `evaluate` means it ran and the take was too short to fill one chunk. Note
`speechStart` is deliberately NOT coupled to `minSpeechChunks` — it stays "first chunk clearing the
threshold" because it is the trim boundary for the leading-silence recovery below. This closes the whole
engine-silence-artifact class in one move
(Qwen3's biased-dictionary echo on silence, Whisper's `Thank you.`, Apple Dictation's `No`), which a string
denylist provably cannot (see below). The gate **fails open**: a missing VAD model, an error, or a
timeout proceeds to transcription unchanged, so the transcript-level checks below remain the mandatory
second line. The ~1 MB model downloads alongside speech models into the shared `models/silero-vad/`.

Because the gate is fail-open, **every STT model added to the catalog must STILL be exercised against
silent/near-silent audio before it ships** — the artifact table below is the second line of defense, not
optional. Engines disagree wildly on what they emit for "nothing was said" and KeyScribe's `.noSpeech`
guard (`DictationMachine.outcomeForTranscript`) keys off the **heard (raw) transcript**, not the final
text: silence short-circuits only because its heard transcript is whitespace-empty, so any non-empty
artifact an engine emits gets pasted, atomically-undoable, and (worse) is indistinguishable from a real
short dictation. (The guard deliberately does **not** whitespace-test the final text — that
would drop a command-only utterance whose output is a bare control char like `"\n"`; it checks the final
text only for emptiness.) Reproduce with the `--raw` benchmark over generated silence:

```bash
# 16k mono clips: pure silence at several durations + quiet hiss + a faint blip
for d in 1 2 3 5; do ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t $d -c:a pcm_s16le sil_${d}s.wav; done
ffmpeg -f lavfi -i "anoisesrc=r=16000:a=0.02:d=3:seed=33" -c:a pcm_s16le hiss.wav
# manifest.json: { "schemaVersion": 1, "clips": [{ "id": "<wav-basename>", "file": "<wav>", "text": "" }, …] }
./KeyScribeDev.app/Contents/MacOS/KeyScribe --benchmark <dir> --engines <new-id> --raw   # RAW\t<engine>\t<clip>\t<literal output>
# And exercise the gate itself over the same clips (verdict + max probability + latency per clip):
./KeyScribeDev.app/Contents/MacOS/KeyScribe --vad-probe <dir>   # silences/hiss → suppressed; real speech → 100% speech
# --chunks adds the per-clip probability vector + how many chunks clear the threshold (the admission axis).
# A clip may state `checks.vad.presence` ("speech"/"noSpeech"); the probe then PASS/FAILs and exits 1 on a
# miss. It fails CLOSED: an expectation whose wav is missing is a failure (corpus wavs are gitignored, so a
# fresh checkout must not report a vacuous pass), and any presence value other than those two fails decoding
# rather than silently dropping the assertion.
./KeyScribeDev.app/Contents/MacOS/KeyScribe --vad-probe corpus/blips           # the admission-rule gate
./KeyScribeDev.app/Contents/MacOS/KeyScribe --vad-probe corpus/commands        # the false-negative floor
```

**Two gates, and a change to `minSpeechChunks` must clear both.** `corpus/blips` is the
suppression side (empty presses that must not be admitted) and carries the whole margin — its
`short_right_now` is the only clip anywhere sitting exactly on the minimum. `corpus/commands` is the
false-negative side: every clip asserts `presence: "speech"`, and they are the shortest real
utterances in the corpus. It is a **coarse** floor, not a fine one — most are `say` TTS
(clean and unclipped, an easier case for VAD than a real fast-release take), and measured today every
clip clears 4+ chunks against a minimum of 2. It catches a gross regression; only `blips` measures the
margin. The population that would actually expose a too-high minimum — a real one-word take clipped by
a fast trigger release — is **declared but not yet recorded**: `corpus/blips`' `clip_*` entries are
fast-release twins of the `short_*` clips, carrying no `checks.vad` until measured (procedure and
decision rule in `corpus/blips/README.md`, "Fast-release twins"). Record those before raising the
minimum — and note that until they exist, no evidence in this repo bounds the false-negative side for a
clipped take.

Empirically observed no-speech output (2026-07-01, one machine — deterministic per fixed input, but
**content-dependent** across different silences, so treat as representative, not exhaustive):

| Engine | Output on silence/near-silence |
|---|---|
| Parakeet TDT v3 / TDT-CTC 110M | `""` (clean empty — greedy TDT discards blanks) |
| Parakeet Unified 0.6B (en) | `""` (clean empty; swept 2026-09-09 over 1/2/3/5 s silence + 3 s and 6 s hiss) |
| Parakeet Ultra | `""` (clean empty; swept 2026-10-13 over 1/2/3/5/7 s silence + 4 s hiss at 0.01–0.05 and 6 s hiss) |
| Qwen3-ASR 0.6B | `""` |
| Whisper Small (en) | bracketed marker `[BLANK_AUDIO]`, **and** parenthetical sound-tags e.g. `(water running)` |
| Whisper Large v3 Turbo | lexical hallucinations: `Thank you.`, `.`, `...` |
| Qwen3-ASR 1.7B | lexical, e.g. `嗯。` / `哦。` (CJK), and on a biased mode an echoed dictionary term |
| Apple Speech (`SpeechTranscriber`) | `""` on silence (swept 2026-09-25 over 1/2/3/5/7 s, batch and streaming); **lexical on white noise**: `.`, `I`, `So` at amplitude 0.02–0.03, `""` at 0.01 and 0.05 (swept 2026-09-26, 4 s and 6 s × three seeds, batch and streaming identical — every clip that emitted text was suppressed by the gate here, but a lone `-` on 6 s of 0.02 noise that passed the gate was reported from another generator) |
| Apple Dictation (`DictationTranscriber`, the fallback) | rare lexical, e.g. `No` (reproduced 2026-09-25 on 3 s silence) |

Qwen3's CJK output is its **language head auto-detecting** on ambiguous noise (`Qwen3DecodingOptions.language`
is deliberately left `nil`; KeyScribe has no language setting and the engine ships multilingual). The fix
is the audio-side gate, not a language pin — do not hardcode `"en"` there.

**Load-bearing conclusion: a string denylist cannot solve this.** The only *safe* strings to strip are
non-lexical annotations no user dictates — bracketed/parenthetical tags like `[BLANK_AUDIO]`,
`(water running)`, `[Music]` (note WhisperKit **does** emit `[BLANK_AUDIO]` here despite upstream docs
calling it a whisper.cpp-only construct — verified empirically, do not trust the docs). The dangerous
outputs (`Thank you.`, `No`, `.`) are real words and must **not** be denylisted — filtering them would
silently drop legitimate one-word dictations. The robust guard for those is the **audio-side VAD pre-gate**
above (was there speech in the audio?) upstream of the transcript, not string matching — now shipped
(`SpeechPresenceGate` / `SpeechPresenceDetector`). This annotation collapse remains for the safe
bracketed/parenthetical strings and as the gate's fail-open backstop. Re-run this the moment a model is
added or an STT dep is bumped — the marker set is engine- and version-specific, and the gate being
fail-open means a new engine's artifacts must still be swept. Validated separation (2026-07-27, one
voice), measured in **chunks clearing 0.30** — the axis admission actually keys on:

| Set | Duration | Chunks clearing 0.30 |
|---|---|---|
| `corpus/blips` empty trigger presses (7) | 0.20–0.51 s | **1** every time (maxP 0.42–0.92) |
| `corpus/blips` shortest real utterance | 0.40 s | **2** |
| `corpus/blips` other short utterances (11) | 0.70–2.85 s | 3–9 |
| `corpus/stt` sentences (106 valid) | — | 6+ |
| generated silence / hiss | — | 0 (hiss maxP 0.198; pure silence never reaches the model) |

Nothing real lands below 2 and nothing empty lands above 1, so `minSpeechChunks = 2` separates them with
the whole gap to itself — but the margin on the speech side is exactly one clip, so **re-measure before
raising it**. `corpus/stt`'s `c69` reads `noSpeech` and that is correct, not a regression: its WAV is 1.1 s
of near-silence that scores WER 1.0 on every engine while its manifest claims an 88-character
sentence — a broken recording worth re-recording, unrelated to this gate. Excluding it, the minimum
take-level max probability over `corpus/stt` is 0.555.

**Admission counts TOTAL clearing chunks, not the longest consecutive run — that is deliberate and
measured.** The intuition that a total count would admit two unrelated noises (press click + release
click) does not survive contact with Silero: it is contextual, so two blips separated by a real gap
score ONE clearing chunk between them, not two (`corpus/blips`' derived `dbl_gap06/10/15/tight` — count
1, run 1, suppressed by either rule). The only derived clip reaching two is `dbl_gap03` (0.3 s gap, the
blips merge), and its run is 2 as well, so a run rule admits it identically. Meanwhile a run rule costs
real margin: `corpus/stt/c72` is genuine speech with **count 6 but longest run 2**, one dropout away
from suppression. `longestRunClearingGate` is kept for diagnostics (`--vad-probe --chunks`), not
admission. `dbl_gap03` is a documented residual gap, not a regression — the old rule admitted it too.

**The inverse failure — VAD heard speech but the engine returned nothing — is recovered, once, generically.**
Parakeet TDT v3 collapses to an all-blank decode on a short take with substantial leading silence
(TDT-v3-only; root cause **unconfirmed** — NVIDIA-NeMo/Speech #15757 is *related* evidence of
silence-sensitive feature normalization, but it is *trailing* silence and a reporter's hypothesis, not a
confirmed diagnosis of this *leading*-silence case). It is a real engine behavior, not one machine's
quirk — observed and verified on a separate machine from the one that verified the recovery. **But there
is no distributable repro:** `corpus/silence-lead/lead_repro1.wav` is a local-only, gitignored,
irreplaceable observation — absent from a fresh checkout, unreproducible by any synthetic construction
tried, so never tune trim behavior against generated clips and never treat a passing corpus run as proof
the bug is gone. Finding a
shareable regression case is open future work; the unit tests are the real safety net. Nothing in the
trigger or the repair is engine-specific, so there is **no `SpeechEngine` hook and no per-engine code**: one
capability-gated policy in `Transcriber.transcribe` re-transcribes the trimmed PCM
(`LeadingSilenceTrim`, KeyScribeKit) when the raw response is empty, the VAD model ran and found speech
after chunk zero (`SpeechPresenceGate.speechStart` — the proof of leading silence), and the engine is
sample-capable with the PCM in hand. The retry runs INSIDE the existing single-flight gate and shares its
one deadline (never extended — it is the wedge protection): it is budget-checked against the first
attempt's elapsed time and skipped rather than risk a spurious timeout. **Never retried:** a nonempty
engine annotation (`[BLANK_AUDIO]` is the engine asserting blank audio, not a silent failure), a fail-open
VAD reading, speech starting in chunk zero, a trim that removes nothing (a `speechStart` of exactly one
chunk — the pre-roll reaches the take's start, so the retry input would be byte-identical and can only
burn the deadline for the same answer), a WAV-only engine (Apple — no trimmed-temp-WAV path exists by
design), or a streamed result (stated policy, not an accident: the session is spent). Never twice. The
256 ms pre-roll is load-bearing — trimming to 0.768 s turns the repro into a different word. Only the
LEAD is trimmed; trailing audio is never touched. **Once the first pass has returned empty, the recovery
owns every later failure:** an engine error or the shared deadline expiring mid-retry both surface as the
named-model terminal, never a generic `Transcription failed`/`timed out` — a failed repair does not change
what happened (the model produced no text on speech). Cancellation alone keeps its own semantics. When no
text survives, the HUD names the model (`Heard speech, but <model> returned no text`) over a `.noSpeech`
record. One `Log.audio` line per dictation records the decision (engine, audio seconds, whether VAD ran,
`speechStart`, attempted/skipped + reason, trimmed seconds, outcome) — never transcript text. **The gate
closure must never log it**: an abandoned closure keeps running and can still return `recovered` for a
dictation the user saw fail, so the decision is RETURNED as a value and logged only once the gate has
ACCEPTED the result (the deadline path logs `retry-deadline` itself). Whoever owns the authoritative
outcome writes the line, so it always matches the terminal. `--vad-probe` prints
each clip's `speechStart` (the trim boundary).

**A streaming session is a DISTINCT no-speech path — sweep it separately.** An engine's `makeStreamingSession`
feed→finalize can emit different silence artifacts than its batch `transcribe`, so a model that ships a
streaming path (`supportsStreaming=true`) must be exercised against silence **both ways**. Use
`--benchmark <sil-dir> --engines <id> --streaming --raw` (raw dumps the literal streamed output per clip)
alongside the batch `--raw`. Include a **≥5 s** silence/hiss clip: the real dictation path defers session
creation past the `StreamingStartPolicy` threshold (4 s), so only clips longer than that actually open a
session live. The benchmark's streaming replay applies the same threshold, so a clip under 4 s reports
`<fell back to batch>` — expected, not a failure; only the longer clips exercise the streaming session.
(2026-07-04, Apple Dictation: streaming output was byte-identical to batch — clean-empty except a
deterministic `No` on 3 s silence, the same documented lexical artifact — so streaming added no new
marker class. 2026-09-26, Apple Speech: streaming output byte-identical to batch over silence and
white noise, including its noise artifacts. Do not assume
that generalizes; a slower or looping engine could differ.) The no-speech gate also covers the streamed path: it runs at commit on the
finished take before `finalizeStreamingIfActive`, so a silent streamed session is suppressed there (its
partials are never inserted before commit) and its driver is cancelled through the normal terminal — the
gate is engine- and path-independent, but the per-engine streaming sweep still stands because the gate is
fail-open.

## Recognition bias — the distractor false-fire gate (exercise every bias-capable model)

**Any engine that ships `supportsRecognitionBias = true` must pass the distractor false-fire sweep
before bias ships enabled.** Run `--benchmark corpus/distractors` (a real phrase acoustically adjacent
to a dictionary term, term never spoken) and `--benchmark corpus/distractors --fuzzy`. The gate is
**substitution fires ≈ 0** over the engine's unbiased baseline — the `sub(bias)` column, fires whose
words are absent from the reference (different words the dictionary put in the speaker's mouth).
**Orthographic snaps are reported but tolerated**: a fire whose words ARE in the reference is the
dictionary snapping spacing/casing ("text field" → "TextField"), which is the dictionary system's
intended behavior — after-transcription recovery does the same by design. The bar and the
counter-example: Qwen3 native context = 0 substitution fires (kept); the removed Parakeet CTC-WS
spotter substituted on 53% of ordinary sentences (removed).
**Re-measured 2026-10-19 on FluidAudio 0.17.7, verdict unchanged.** Every configuration failed the
gate on both Parakeet TDT v3 and Parakeet Ultra: the July pairing reproduced; the SDK defaults with the
documented CTC 110M companion were worse; the acoustic rescue off and the documented short-term floors
and taper still substituted into a quarter to a third of ordinary sentences; and a verify-only policy
over the SDK's non-mutating candidate-evidence API, accepting a candidate only when the acoustic
comparison AND the text gate both passed, was clean on distractors but recovered nothing the text
rules do not already recover — its only gains and all of its new substitutions were multi-word
phrases ("Yuga Bite" → Yugabyte vs "fast app" → FastAPI), and the acoustic margins favored the wrong
ones. The failure lives in the CTC comparison and candidate discovery, not in which Parakeet model
transcribes, so do not re-run it per model; re-open only for a mechanism that is not a CTC
comparison against a sound-alike phrase.
The `supportsRecognitionBias` seam, the `biasTerms` plumbing through the pipeline, and this corpus ARE
the re-entry path for a future engine that biases cleanly — nothing else is kept for that purpose; the
removed spotter lives in git history only.
