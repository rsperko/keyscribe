# Dictionary, recognition bias, and recovery — findings

What has been measured about getting a user's dictionary spellings into the inserted text, and the
rules those measurements support. `docs/development/design.md` §4.2 states the shipped rules; this
file keeps the evidence so a later change does not re-run a lost experiment.

Two questions bring people here. Both have a short answer and a long one.

- **"Parakeet cannot transcribe Yugabyte."** Short answer in §1; what each model does with a
  dictionary in §3; why the obvious fix (bias) is off for Parakeet in §4.
- **"Let's add bias to Parakeet."** Every attempt so far, with its numbers, in §4; what a new
  attempt has to clear in §8.

Conventions: every number is dated and names the corpus and harness that produced it. A number
without a date is a tally and does not belong here. Audio is one developer's voice or `say` speech
unless a row says otherwise; nothing here is a benchmark of the engines in general.

---

## 1. The short answer for a term Parakeet keeps missing

No Parakeet model uses the dictionary while it listens. The
dictionary reaches its output only after transcription, through `FuzzyStage`, which fixes a term
that came out close to right and leaves one that came out as different words.

For "Yugabyte" on synthetic speech (45 sentences, 9 distinct `say` voices, 144 term slots, measured
2026-10-19 with the bias re-run harness):

| Engine | Slots right raw | Slots right after recovery |
|---|---:|---:|
| Parakeet TDT v3 | 42 | 70 |
| Parakeet Ultra | 34 | 101 |

What the recovery fixes and misses, by heard form (same data):

| Heard | Recovered today | Why |
|---|---|---|
| `Ugabyte`, `Gugabyte`, `Yogabyte` | yes | one edit, same consonant skeleton |
| `YugaByte`, `Yuga byte` | yes | casing or spacing only |
| `Yuga Bite`, `Yuka Bite`, `Luka byte` | no | a near match never joins split words (§5) |
| `UGBte`, `Ugaby`, `YugaBy` | no | three edits; the cap is two from seven letters (§5) |
| `you to fight`, `rebite` | no | not a near match of anything |

On the single-sentence set (15 clips, 4 Parakeet models, 2026-10-19), TDT-CTC 110M and Unified
wrote `Yugabyte` raw on 11 and 8 of 15 clips; TDT v3 and Ultra never did raw and reached it through
recovery on 8 and 13. The recorded (not tabulated) observation is that Whisper Large v3 Turbo and
Qwen3-ASR 1.7B hear the term from the audio and bias toward it.

What to tell the user, in order:

1. **A Replacement for the heard form** (`yuga bite` → Yugabyte, `ugbte` → Yugabyte). It is exact,
   every time, on every engine, and History shows the heard text to copy. This is the supported
   path for a form recovery cannot reach, and it is the only path that also works with no LLM.
2. **A model that biases while listening** (Whisper Large v3 Turbo or Qwen3-ASR 1.7B) if they say
   many such terms: §3 shows the recall gain.
3. Keep the term in the dictionary regardless; it still fixes the one-edit forms and tells an AI
   rewrite not to "correct" it.

Not known: what real users' voices produce. Every heard form above is `say` speech. Ask for two or
three heard strings from the History pane before judging a rule against a report.

---

## 2. How a dictionary term reaches the text

1. **Decode-time recognition bias**, only on models whose catalog entry says
   `supportsRecognitionBias` (`SpeechModelCatalog.all`): Qwen3 through its native context, Whisper
   through decode-time prompt tokens. Parakeet and Apple do not bias; §4 is why.
2. **After-transcription recovery** on every engine (`FuzzyStage` over `FuzzyCorrector`): exact
   casing and spacing snaps for any window, and a single-token near match gated by a
   consonant-skeleton key and an edit cap (§5). Runs whenever the mode's merged dictionary is
   non-empty; there is no toggle.
3. **For an AI rewrite**, the terms present verbatim in the (already tokenized) text are sent as a
   "valid, not a misspelling" hint (`RewriteRequestBuilder`). Nothing else from the dictionary is
   sent (§6).

---

## 3. What each model does with a dictionary

### Term recall on the developer corpus

`corpus/stt`, 107 clips of one voice, 51 of them carrying dictionary terms, each clip given exactly
the terms it speaks (an idealized dictionary). "Raw" and "bias" from the run of 2026-10-14
(`--benchmark corpus/stt`); "recovery" columns from the `--fuzzy` run of 2026-10-19. Both runs are
the shipped rules of their date.

| Model | Raw | Bias only | Recovery only | Bias + recovery |
|---|---:|---:|---:|---:|
| Whisper Large v3 Turbo | 81% | 96% | 89% | 96% |
| Qwen3-ASR 1.7B | 84% | 94% | 91% | 97% |
| Whisper Small (English) | 78% | 95% | 88% | 97% |
| Qwen3-ASR 0.6B | 77% | 93% | 88% | 96% |
| Parakeet Ultra | 81% | — | 91% | — |
| Parakeet Unified 0.6B (English) | 80% | — | 91% | — |
| Parakeet TDT v3 | 77% | — | 89% | — |
| Parakeet TDT-CTC 110M | 67% | — | 86% | — |
| Apple Speech | 53% | — | 64% | — |

Reading it:

- Recovery alone lifts every engine by 7–19 points and lowers WER on the term-dense corpus
  (Parakeet TDT v3 8.3% → 7.2%, Ultra 7.1% → 6.3%, same runs).
- Bias alone beats recovery alone on every model that has it, and the two together add a little
  more. The gap between a Parakeet model with recovery and a Whisper or Qwen model with both is
  5–11 points of term recall; that gap is what a user who dictates many terms is choosing between.
- Apple is the outlier on both: its raw recall is the lowest and recovery closes the least of it.

### False fires on the distractor corpus

`corpus/distractors`: 34 ordinary sentences acoustically next to a term and 10 control sentences
that speak one, three `say` accents each, a 10-term dictionary active on every clip. A fire is a
dictionary term in the output that the reference does not contain. A **substitution** fire puts
words in the speaker's mouth ("lava" → Java); an **orthographic** fire respells words the speaker
said ("text field" → TextField) and is the dictionary doing its job.

| Model | Substitution fires, bias on | Orthographic fires, bias on / off | With recovery: substitution / orthographic |
|---|---:|---:|---:|
| Whisper Large v3 Turbo | 0 | 9 / 6 | 0 / 18 |
| Whisper Small (English) | 0 | 11 / 4 | 0 / 18 |
| Qwen3-ASR 1.7B | 0 | 0 / 1 | 0 / 18 |
| Qwen3-ASR 0.6B | 0 | 0 / 0 | 0 / 18 |
| Parakeet (every model) | — | 0 / 0 | 0 / 18 |
| Apple Speech | — | 0 / 0 | 0 / 18 |

Bias-only columns from the run of 2026-08-09, recovery columns from 2026-10-19. The 18 orthographic
fires under recovery are the same 18 on every engine: the exact-join rule snapping the control
clips' compounds, which is the behavior the control clips exist to confirm. Whisper's prompt bias
adds a few orthographic snaps of its own; Qwen's context adds none. No shipped mechanism has ever
produced a substitution on this corpus. The removed Parakeet spotter did, on half of it (§4).

### What the dictionary cannot do on any model

Split forms (`Yuga Bite`), dropped-letter forms (`UGBte`), and mishearings that are other real
words (`you to fight`) are not recovered by any shipped mechanism, and §5–§6 record why every rule
tried for them was withdrawn. They are Replacements.

---

## 4. Recognition bias on Parakeet and Apple — every exploration

The dictionary has been wired into a decode-time mechanism on every engine family at some point.
Whisper and Qwen3 kept theirs; Parakeet and Apple lost theirs after measurement, and the Parakeet
one was measured again three months later. In order:

### 2026-06 — everything biased (the pre-KeyScribe build)

The build this project grew from fed one term list into a decode-time mechanism on each engine:
Parakeet through FluidAudio's CTC keyword spotter (the 110M CTC companion, `configureVocabularyBoosting`,
with the sliding-window confirmation gate lowered because the default 10 s of context meant bias
never fired on a sentence-length dictation), Whisper through `promptTokens`, and Apple through
`AnalysisContext.contextualStrings`. Each was described as "real, not a hint". None had been
measured for false fires.

### 2026-07-05 — the benefit side, measured alone

`corpus/bias` was built (entity-dense ContextASR-Bench clips, 20 clips of 26–77 s) and run on
Parakeet TDT-CTC 110M with its spotter: term recall 33% → 69%, WER 20.1% → 19.2%. On a corpus that
only speaks terms, bias looks like a clear win. This is the measurement that made the spotter
look safe, and it is the reason the distractor corpus exists: a term-dense corpus can only see the
benefit.

### 2026-07-08 — the rescue toggle

FluidAudio accepted `spotterRescueEnabled` upstream (their #724), which lets the weaker CTC 110M
skip the acoustic-only rescue pass; the project's fork carrying that toggle was dropped.

### 2026-07-09 — the distractor sweep, and the removal

72 clean distractor sentences and 24 control clips, one machine:

| Mechanism | Distractor sentences that gained a term never spoken | Control-term recall | Outcome |
|---|---:|---:|---|
| Parakeet CTC spotter | 41–42 / 72 | 100% | Removed |
| Apple `contextualStrings` | 14 / 72 | 42% | Removed |
| Whisper prompt tokens | 3–8 / 72 | 92% | Kept |
| Qwen3 native context | 0 / 72 | 75–79% | Kept |

The spotter's failures were ordinary sound-alike phrases becoming terms. Lowering its thresholds
left 36–38% false fires, so tuning was not a fix. Apple's bias false-fired a fifth of the time and
recovered under half of the control terms, the worst of both. Both were removed in one change;
Parakeet became TDT-only, the CTC download and its disk footprint went with it, and
`supportsRecognitionBias` became the per-model capability it is now. Recovery
(`FuzzyStage`) was made unconditional on every engine in the same change, because the dictionary
still had to do something on the engines that lost bias.

### 2026-10-19 — re-measured on FluidAudio 0.17.7

Reopened because the SDK had changed in ways that could matter: a non-mutating candidate-evidence
API (their #805), unified-model vocabulary support with upstream-measured recall gains (#862), fixes
for silently ignored terms (#898) and for a detection landing on a distant unrelated word (#900).
A standalone harness outside the app; Parakeet TDT v3 and Ultra; 451 clips per engine (45 Yugabyte
sentences in 9 voices, the 132 distractor and control clips, 78 adversarial confusable phrases,
`corpus/stt`, `corpus/bias`, `corpus/commands`, 21 blips, 10 silence clips); three dictionaries
(the 10-term distractor list, `Yugabyte` alone, a 49-term list). No threshold was tuned. Every
biased transcript went through the shipped text stage too, so gains are over recovery, not over raw.

Distractor sentences that gained a wrong word, out of 102 (v3 / Ultra):

| Configuration | Wrong word added | Term recoveries over recovery alone | Word errors, recovery → biased (v3, of 10,657) |
|---|---:|---:|---:|
| July control (CTC 0.6B, rescue on) | 53 / 52 | +116 / +94 | 1001 → 1757 |
| SDK defaults (CTC 110M, rescue on) | 94 / 96 | +131 / +112 | 1001 → 1937 |
| Rescue off | 33 / 33 | +97 / +72 | 1001 → 1243 |
| Documented floors + short-term taper | 25 / 25 | +115 / +90 | 1001 → 1180 |
| Verify-only (evidence API + the shipped text gate) | 0 / 0 | +34 / +23 | 1001 → 1074 |

Findings:

- July reproduces. The SDK's current defaults are worse: rescue inserted `Yugabyte` into 29 ordinary
  sentences from a one-term dictionary ("Our local communities came together" → "Yugabyte
  together"). Rescue off and the documented controls still rewrite a quarter to a third ("dust" →
  Rust, "lava" → Java, "type of script" → TypeScript, "grafting" → Grafana).
- Verify-only is clean on distractors and recovers nothing the text rules do not already recover.
  Every one of its gains was a multi-word candidate ("Yuga Bite" → Yugabyte), and so was every one
  of its 58 new substitutions ("fast app" → FastAPI, "open app" → OpenAPI, "get lab" → GitLab,
  "air flaw" → Airflow). The acoustic margins overlap and sometimes favor the wrong one: the
  unboosted comparison scores "open app" → OpenAPI at +3.7 and "fast app" → FastAPI at +0.55
  against "Yuga Bite" → Yugabyte at −0.66. The CTC evidence measures sound, and these confusions
  are sound-alike by construction.
- The harm is in the CTC comparison and candidate discovery, not in which Parakeet model
  transcribes, so Unified and 110M were not run and a per-model re-run is not owed.
- Costs for the record: the CTC 110M pass is about 95 ms per short dictation over a 35 ms decode,
  CTC 0.6B about 245 ms and 2.3 GB on disk; Neural Engine memory was not established. The 110M CTC
  scores differently on the Neural Engine and GPU under macOS 27 (NaN on CPU alone); the verdict
  was the same on both.

**Verdict, both times: unsuitable.** The decision stands until a mechanism that is not a CTC
comparison against a sound-alike phrase clears the gate in §8.

### Not tried

Recorded so the next person does not mistake them for closed:

- **Boosting inside the TDT decoder itself**, without a CTC companion: a phrase-prefix reward
  applied only to tokens the model already rates plausible (a relative-probability gate). One
  browser port of Parakeet describes this; NeMo's own word-boosting tree lives in its Python
  decoder, and sherpa-onnx's Parakeet hotwords are a runtime swap with open hallucination reports.
  FluidAudio already reads top-K logits in its v3 decoder for language filtering, so the seam may
  exist, but this is SDK work and top-K truncation may hide the token that needs the boost.
- **Unified-model vocabulary** (FluidAudio #862, upstream-measured 51% → 89% vocabulary recall on
  earnings calls). It rides the same CTC rescoring path, so the distractor result is expected to
  carry, but it has not been run.
- **Parakeet bias on human recordings of a hard term.** Every Yugabyte clip is `say` speech.

---

## 5. After-transcription recovery — rules and the measurements behind them

`FuzzyCorrector` is the one mechanism that runs on every engine, so every rule in it is measured
against what else it rewrites, not only against what it recovers. The sweeps, in order of weight:
the system word list (`/usr/share/dict/words`), a product-name list, a replay over raw engine output
of the corpora, and the adversarial negatives pinned in `FuzzyCorrectorTests`. The distractor
corpus counts against a rule, never for it. Deny lists of words are not an option; they are owned by
nobody.

### A recovery rule is judged by what else it rewrites (2026-10-20)

A rule that recovered one observed form, a long term heard with its vowels dropped (`UGBte` for
Yugabyte), was added, gated, and removed within days. The form it recovered was real; the sweeps
decided against it:

- Over the system word list, the rule rewrote everyday words into longer dictionary terms (golden
  → GoldenEye, grant → Guaranty, sprat → Separate) whenever the term happened to be in the
  dictionary alone.
- A gate on the heard token's casing ("an engine writes a token it spelled, not recognized, with a
  capital inside it") held on Parakeet output and failed on others: Whisper Small emits `[MUSIC]`
  and acronym plurals (CDs) carry interior capitals on several engines. Measured over 259 clips per
  engine: Apple 13 mixed-case tokens, Parakeet 110M 22, Unified 30, Qwen3 0.6B 34, Qwen3 1.7B 20,
  Whisper Large 40, Whisper Small 34, all product names, acronym plurals, or spelled-out
  mishearings (`BitePuter`, `TypeSgrid`).
- A gate that saves a rule is a second rule. It needs its own sweep, and the first time it needed
  tightening was the signal to stop.

### A second edit only from seven letters (2026-10-20)

The near match used to allow a second edit from six letters. A six-letter word two edits from a
six-letter term with the same consonant key is common English ("cloudy" → Claude, "access" → Chess,
"number" → Member), and those were the largest source of wrong rewrites. Measured with a policy
switch on the near-match branch only, over four inputs: a replay of raw output from nine engines
over `corpus/stt`, `corpus/distractors`, `corpus/bias` and the synthetic Yugabyte clips, against a
56-term developer dictionary (a change toward the reference is a recovery, any other change is
wrong); 7,533 code identifiers, each heard as another with only that other in the dictionary; 4,132
distinct prose words; and the 232,989-word system word list. Every rewrite in the last three is
wrong.

| Policy | Replay recovered | Replay wrong | Identifiers | Prose | Word list |
|---|---:|---:|---:|---:|---:|
| second edit from six letters (old) | 68 | 46 | 449 | 213 | 3,698 |
| exact only below five letters (heard word) | 62 | 36 | 396 | 162 | 3,092 |
| no prefix/suffix match | 38 | 46 | 320 | 176 | 3,243 |
| second edit from seven letters (shipped) | 63 | 19 | 399 | 167 | 2,434 |
| both of the first two restrictions | 57 | 9 | 346 | 116 | 1,828 |

Seven letters halves the replay's wrong rewrites for five lost recoveries; what it loses is a
six-letter name two edits off ("Sophia" no longer snaps to Sofia). Forbidding a prefix or suffix
match was rejected: it kills the main Parakeet recoveries ("Ugabyte" → Yugabyte, "postgress" →
Postgres), which have the same shape as the wrong rewrites it stops. One edit on a five- or
six-letter same-key word still snaps and is pinned as a known limitation
(`knownLimitationOneEditOnAFiveLetterSameKeyWordSnaps`: rebake → rebase, check → Chuck); shorter
words are covered by the first-name entry below. The replay is synthetic or single-voice audio, and a few sentences
repeated across engines dominate its counts, so the three exposure sweeps carry more weight.

Rule: an edit-cap change is chosen by the exposure sweeps first and the replay second.

### A near match needs every letter in the key's alphabet (2026-10-20)

The consonant key reads A–Z only, so a word in Cyrillic, Greek, or CJK keyed to an empty string and
"matched" any term with an empty key within the edit cap (в Москве → в Москва, собака → соната). A
near match now requires both words to be entirely a–z or 0–9 after accents are folded and letters
with no accent-free form are spelled out (ß → ss, æ → ae, œ → oe, ø → o, ł → l), and computes the
key and the distance on that form. Exact casing and spacing snaps still apply in every script.
Pinned by `neverFuzzesAWordThePhoneticKeyCannotSee`, `nonLatinTermsStillSnapCasingAndSpacing`, and
`latinLettersWithoutAnAccentFormStillRecover`.

Rule: a fuzzy gate may only judge text it can see; outside that, the stage does exact matching only.

### Split words are never joined by a near match (2026-10-19)

Every local split-word rule tried (a three-character token floor with distance one; same length with
a single vowel swap) rewrote ordinary two-word phrases: "fast app" → FastAPI, "open app settings" →
OpenAPI settings, "the centre of the room" → Accenture (a subsequence variant let consonants vanish
because the key collapses doubled consonants). Those phrases are now the adversarial negatives in
`FuzzyCorrectorTests`, and the exact-join rule is the only multi-word recovery. Its own cost is
pinned, not hidden: `exactJoinOfTwoCommonWordsStillRewrites` ("the red is bright" → "the Redis
bright", "a work day" → "a Workday", "the key chain" → "the Keychain"). Tightening it costs the
legitimate joins ("charge bee" → ChargeBee) and is a product decision, not a rule change.

### A near match needs five letters in both words (2026-10-20)

The near match allowed one edit from four letters and keys on consonants only, so a four-letter
name is one vowel swap from a common word with the same consonants. Measured with
`FuzzyCorrector.apply`, each name alone in the dictionary, on the old rule:

| Dictionary term | Dictated | Inserted |
|---|---|---|
| Mike | make sure it works | Mike sure it works |
| John | join the call | John the call |
| Dave | dive into it | Dave into it |
| Bill | the bell rang | the Bill rang |
| Will | the wall is high | the Will is high |
| Kate | a kite flew | a Kate flew |
| Jane | in June we ship | in Jane we ship |
| Nick | a neck brace | a Nick brace |
| Rick | a rack of lamb | a Rick of lamb |

Pete, Liam, Marc, and Mark fire the same way; Matt, Sara, Anna, Tim, Sam, Luke, Kyle, Ryan, and
Noah do not, because their nearest common word is two edits away or under the four-letter minimum.
The reach of the rule over the system word list: 12,765 of 14,987 four- and five-letter words have
a same-skeleton neighbor one edit away (list → last, farm → form, most → must). First names are the
dictionary's advertised use, and the stage runs on every engine, so every user who added one of
these names sees it.

The fix: a near match needs both the heard word and the term to have at least five letters; below
that, only the casing, spacing and accent fix applies ("mike" → Mike, "Jose" → José). The cutoff
was chosen by a sweep of every four- to six-letter name in `/usr/share/dict/propernames`, each
alone in the dictionary, against the 4,132 prose words and the system word list, plus the policy
replay and sweeps above. Measured 2026-10-20, names with at least one colliding word (prose / word
list):

| Policy | 4-letter names (219) | 5-letter (341) | 6-letter (321) | Replay recovered | Replay wrong | Identifiers | Prose | Word list |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| one edit from four letters (old) | 73 / 207 | 36 / 275 | 13 / 240 | 63 | 19 | 399 | 167 | 2,434 |
| five letters, heard word only | 16 / 137 | 23 / 248 | 13 / 240 | 57 | 9 | 346 | 116 | 1,828 |
| five letters, both words (shipped) | 0 / 0 | 23 / 248 | 13 / 240 | 57 | 9 | 333 | 100 | 1,641 |
| six letters, both words | 0 / 0 | 0 / 0 | 9 / 222 | 49 | 9 | 289 | 65 | 1,151 |

Gating the heard word alone leaves a five-letter word snapping to a four-letter name (handy → Andy,
email → Emil, early → Earl, voice → Vice) at no saving in the replay, so the term is gated too.
Five letters loses Quen → Qwen, Enya → Anya and Pria → Priya from the replay
(`knownLimitationAShortMishearingIsNotRecovered`). Six letters would also stop the five-letter
names (check → Chuck, hurry → Harry, every → Avery, match → Mitch, shown → Shawn) but loses
five-letter terms an engine misspells (Rediz → Redis, Tiago → Thiago, Rajes → Rajesh, EngineX →
Nginx), and six-letter names still collide (vector → Victor, manual → Manuel, visual → Vishal), so
no length cutoff ends the class. The five-letter collisions are pinned in
`knownLimitationOneEditOnAFiveLetterSameKeyWordSnaps`; a user who hits one, or needs a short name
recovered, adds a literal replacement.

Rule: a length gate on a near match applies to both words, because a collision runs in both
directions.

---

## 6. Term hints to the LLM

### The present-only hint, and why it is the only one (from history, 2026-10-20)

The app has never sent the whole dictionary. The filter that sends only terms present in the text
is in the first commit (2026-06-22). It runs over the content after the forward pipeline
(`DictationController.rewriteTokenized` hands `RewriteRequestBuilder` the tokenized text), so a term
inside a redacted span is not present in what the filter sees and is not hinted.

`PromptAssembler` also carries a paired-hint rule ("the transcription may have misheard these
dictionary terms … replace it with the term shown"), fed by `PromptInputs.fuzzyCandidates`. The app
has passed it an empty list since 2026-07-10. The channel was added on 2026-07-09 (up to ten
`FuzzyCorrector.candidates` pairs over the merged dictionary) and emptied the next day; the reason
survives in the test that pins it (`buildDoesNotHintFuzzyCandidates`): the local stage had already
snapped every window the candidate finder could pair, so the hint never carried anything the text
did not already show, and it was unwanted on a selection rewrite. A design note of the time
recorded the channel as graduated with measured gains; the test was right and the note was stale.
The eval harness still fills the channel (`RewriteEvalVariants`), which is how a candidate rule can
be measured without the app sending one.

Rules:

- A candidate finder that reaches the model must be looser than the snapper, or it measures
  nothing: whatever it reports has already been rewritten locally.
- Term hints are built from the dictionary, not from the content, so they sit outside the
  redaction pass. Anything that feeds the hint list has to be free of secrets on its own; a user's
  dictionary filtered to terms present in the tokenized text satisfies that.
- When a note and a shipped test disagree about what runs, the test decides; correct the note.

### A looser candidate channel was measured and rejected (2026-10-19)

A finder that offered the model every two-word window within one edit of a term (equal phonetic
key, not an exact join), and separately within two, was run through `--rewrite-eval` with
`--repeat 3`. Gemini 3.1 Flash Lite (preview) accepted every negative it was offered, on every
attempt ("Please OpenAPI settings", "Datadog is done"), and also took the ChargeBee distractor;
Qwen3-Coder 30B accepted "fast app" and "air flaw". Gemini restored "Yuga Bite" → Yugabyte with no
hint at all, from the prompt's ordinary cleanup. The model does not decline a sound-alike hint from
sentence context, so the hint is never sent. The `split-word` cases in `evals/rewrite` stay as the
bar any candidate channel has to pass.

### A text-only model cannot be handed sound-alike terms (2026-10-20)

MacWhisper sends its whole on-screen word list on every request and asks the model to prefer those
words "if they match the dictated audio". A text-only model never hears the audio, so the question
was whether the list alone, in any wording, lets the model fix what the local stage misses (split
forms such as "Yuga Bite", "Uka byte", "UGBte") without rewriting ordinary phrases that sound like a
term.

A bare list was probed directly against two local models, six recoverable forms and six sound-alike
phrases, the whole eleven-term dictionary on every request, three repeats, temperature 0.2:

| Model | Rule wording | Forms recovered | Sound-alikes left alone |
|---|---|---:|---:|
| Qwen3-Coder 30B | none | 0/6 | 6/6 |
| Qwen3-Coder 30B | "write the term where the text clearly refers to it; leave phrases that merely sound similar" | 4/6 | 6/6 |
| Qwen3-Coder 30B | MacWhisper's "strongly preferred if they match" | 3/6 | 6/6 |
| Qwen3.6 27B | none | 0/6 | 6/6 |
| Qwen3.6 27B | "clearly refers / sounds similar" | 5/6 | 3/6 |
| Qwen3.6 27B | MacWhisper's | 5/6 | 5/6 |

What this fixed is real: the split forms came back as the dictionary spells them on both models.
What it broke decides it: on the model that over-accepts, "there is an air flaw in the design"
became "There is an Airflow in the design" on every repeat, and the hedged wording did worse than
the blunt one.

The harness run (2026-10-20, `--rewrite-eval evals/rewrite`, 51 cases, three repeats) compared each
dictionary variant against production's own term handling (the local stage, then verbatim-present
terms), not against a prompt with no terms, so a gain the stage already makes is not credited to the
list. The dictionary was a shared 23-term developer list plus each case's terms:

| Model | Variant | Cases fixed | Cases broken |
|---|---|---:|---:|
| Gemini Flash Lite (latest) | whole list, "garbled version … leave words that already make sense" | 6 | 7 |
| Gemini Flash Lite (latest) | whole list, MacWhisper's wording | 5 | 6 |
| Gemini Flash Lite (latest) | same-key subset, "garbled version" wording | 5 | 7 |
| Qwen3-Coder 30B | whole list, "garbled version" wording | 4 | 1 |
| Qwen3-Coder 30B | whole list, MacWhisper's wording | 1 | 1 |
| Qwen3-Coder 30B | same-key subset, "garbled version" wording | 3 | 1 |

Gemini's breaks were the sound-alike cases on every wording ("The paint dried to a FluidBloo
sheen", "The ChargeBee on that account was waived", "Datadog is done"). Telling the model to leave
words that already make sense as written changed nothing. Qwen left every sound-alike alone, but
with a list in the prompt it dropped a protected `⟦SN:…⟧` token from a sentence that also named a
term: one attempt in three with the whole list, every attempt with the subset, and none with
MacWhisper's wording. The validation gate catches that and falls back to the raw transcript, so it
costs the rewrite rather than leaking.

The same run, re-scored against a pass bar set before looking (2026-10-20): a wording ships only if
it drops no protected token on either model and fixes more than it breaks on the floor model. No
wording passes. Gemini fixed the same five cases on every wording (the split and dropped-letter
Yugabyte forms, "fluid blue", "cloud code"; its sixth, a locale spelling, did not reproduce) and broke
every sound-alike case it was offered. Qwen's best wording on breaks, MacWhisper's, fixed one case and
broke the Japanese email on two attempts in three. Every case the list fixed was a fixed heard
string a literal replacement covers, so the list adds nothing a replacement learned from History
would not.
Qwen also wrote "YugaByte" and "FluidBlue", one letter or one capital off the dictionary spelling;
a recovery the model makes still needs an exact-spelling check.

Gating the hint on a non-word in the heard text was considered and not built. Every sound-alike
case is made of real words, but so are two real recoveries ("fluid blue" for FluidBloo, "cloud code"
for ClaudeCode), and the system word list cannot serve as the lexicon: it lists "yuga" and lacks
"byte", "app", and "sales".

Rules this supports:

- Safety is a property of the model, not of the list or its wording. A connection the user picked
  cannot be assumed to decline a sound-alike, so the default prompt sends only terms present
  verbatim.
- Selecting a subset of the dictionary (terms with the same consonant key as something in the text)
  does not buy safety: the selector keeps exactly the term that causes the false fire. It buys a
  shorter prompt and keeps unspoken terms on the machine, which matters because the dictionary
  leaves the machine in privacy modes too (`FAQ.md`, "What does the dictionary do").
- A hint that names a term more directly moves the model further toward it: a paired hint is
  accepted outright, a bare list is accepted by some models, a verbatim-present hint is safe. The
  deciding fact for a sound-alike is in the audio, which only the recognizer has.

Split forms and dropped-letter forms therefore recover only through a literal replacement, written
by the user or learned from History.

### What a whole-list competitor actually sends (2026-10-20, live capture)

One MacWhisper (build 1553) request to an OpenAI-compatible endpoint was captured through a logging
proxy: listen on a spare loopback port, write each request body to a file, forward to the real
server. (oMLX logs timings, not bodies, so the proxy is the way to see the prompt.) The request was
one system message and one user message, `stream: true`, no sampling parameters. The system message
is its proofreader prompt, then the word list introduced as "appear on the user's screen or were
previously added and should be strongly preferred if they match the dictated audio", then a fixed
tail (punctuation words to symbols, same language as the transcript, return only the transcript,
never start with backticks, no leading or trailing whitespace). The user message is
`Dictation transcript:` and the text.

The list that went out had about 330 entries. Five were dictionary terms. The rest was a screen
scrape, sorted case-sensitively: function words ("and", "the", "to"), shell words ("curl", "cd",
"cat"), path and file-name fragments with their punctuation stripped, misread names, and an API key
that was visible in a terminal, also with its punctuation stripped. The list follows whatever window
is open, so two dictations of the same sentence get different hints.

Rules this supports:

- The measurement above used a clean eleven-term list; the shipped list is far noisier, so that
  comparison is generous to the whole-list approach.
- A screen harvest with no lexicon filter sends whatever is on screen, secrets included, on every
  request, and the connection can be remote. A harvest channel, if one is ever built, needs a
  filter that keeps only tokens that are not already words, and it still sits outside redaction.
- To recapture after a competitor update: point the app at the proxy port, dictate once per mode,
  read the file. One dictation per mode is enough; the list is the variable part.

---

## 7. Harnesses and where the data lives

| Question | Harness | Data |
|---|---|---|
| Term recall and WER per engine, with and without bias | `KeyScribe --benchmark corpus/stt [--fuzzy]`, ranked by `corpus/compare.sh` | `corpus/stt/results.json`, `results-fuzzy.json` (gitignored, one voice) |
| False fires per engine | `--benchmark corpus/distractors [--fuzzy]` | `corpus/distractors/results*.json` |
| Bias stress on entity-dense long clips; new-engine onboarding | `--benchmark corpus/bias [--streaming] [--raw]` | `corpus/bias/results.json` |
| What a rule does to raw engine output | `--benchmark <dir> --raw`, then the text rule over the `RAW` lines | the corpora above |
| Recovery rules in isolation | `FuzzyCorrectorTests` (adversarial negatives, known limitations) | — |
| LLM term hints | `--rewrite-eval evals/rewrite --connection <id> --repeat 3` | `evals/rewrite/README.md` records each variant's verdict |

The Yugabyte sets, the bias re-run harness, and the word-list sweeps are local, dated artifacts;
this file carries their numbers so they do not have to be found again.

---

## 8. Before proposing bias for Parakeet again

The gate, unchanged since July: `--benchmark corpus/distractors` and `--benchmark corpus/distractors
--fuzzy` with the mechanism on, **substitution fires ≈ 0 over the engine's unbiased baseline**, with
control-term recall still up. Orthographic snaps are tolerated. Then the same two sweeps over
`corpus/stt`, and the no-speech sweep from `AGENTS.md` (bias content does not cover silence). A
result from one engine or mechanism says nothing about another.

What a new attempt should do, in the order that spends the least to learn the most:

1. **Start from real heard forms.** Ask for History "heard" strings from the users reporting the
   term, with the engine and whether the mode has an LLM rewrite. If their shapes are already in §1
   there is nothing new to measure; if they are not, add them to the Yugabyte set first. Every
   verdict in §4 is on `say` speech.
2. **Do not re-run a CTC comparison.** Three configurations of it and a verify-only policy over its
   evidence API all failed the same way, on two Parakeet models, three months apart. Its failure is
   that it scores sound, and the phrases it wrongly accepts are sound-alikes by construction. A
   fourth threshold will not change that.
3. **If the mechanism is new, name what makes it not a CTC comparison** before building: decoder-
   internal boosting gated on the model's own plausibility (§4, "Not tried") is the one direction
   with a reason to expect a different answer, because it cannot propose a term the acoustic model
   did not already rate as possible. It is SDK work; budget it as such.
4. **Measure benefit and harm together, over a realistic dictionary.** The 2026-07-05 bias corpus
   run showed a 36-point recall gain and said nothing about the 53% false-fire rate found four days
   later. A real dictionary mostly holds terms the current dictation does not say, which is exactly
   the condition under which a spotter fires wrongly; the 49-term list in the October re-run is the
   closest stand-in so far.
5. **Compare against recovery, not against raw.** The shipped text stage already closes 10–19
   points of term recall on every Parakeet model (§3). A mechanism's gain is what it adds over that,
   and its cost is every transcript it makes worse; the October table reports both.

Until something clears that, the answer to "Parakeet cannot transcribe X" is §1: a Replacement for
the heard form, or a model that biases.
