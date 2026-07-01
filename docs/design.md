# KeyScribe — High-Level Design

> The architecture of the app. Governed by `principles.md`.
>
> User-facing implementation contracts: `ui_design.md` defines the UX, HUD, Settings, menu bar,
> History, and accessibility behavior; `ui_components.md` defines the shared widget vocabulary;
> `icon_design.md` defines the app-icon and menu-bar glyph direction.

---

## 1. Vision

**KeyScribe is a privacy-first, local-first voice dictation app for macOS that is simple by
default and deeply configurable when you want it to be.**

Power comes from composing data-driven modes, pipeline stages, regex, and prompt context.
KeyScribe is not a scripting or plugin platform (YAGNI, `principles.md` §7).

Speech recognition always runs **on-device** — audio never goes to the cloud. The text that
STT produces then flows through a **staged command pipeline** that is as much of the product
as the recognition itself: dictionaries, replacements, live edits, verbatim spans, and
**privacy redaction with restoration**. An **optional** BYOK LLM rewrite step can polish the
result — and because that step *can* be cloud, best-effort redaction lowers what leaves the machine:
recognizable sensitive content is tokenized out before the request and restored after.

### Positioning in one line
> *"Apple Dictation's simplicity, Superwhisper's power, and a privacy story neither cloud
> tool can match — STT always local, sensitive data tokenized before any optional cloud
> rewrite."*

### The wedge
1. **Privacy-first, simple** — STT is always local; the default experience is clean and
   unintimidating. Redaction + restoration reduce optional cloud rewrite payloads without pretending
   they are a security boundary.
2. **Post-processing is the product.** The transform from raw speech to finished text is an
   explicit, staged pipeline — not the opaque single LLM step competitors ship.
3. **Progressive disclosure** — the full power ships, but lives behind Advanced surfaces so
   it never burdens a casual user. *Simple by default, powerful on demand.*

### Hard invariants
- **STT is always on-device. There is no cloud STT, ever.**
- **Exactly one STT engine is active at a time** — chosen globally in settings and used
  everywhere. (Multiple named *LLMs* are allowed; STT is singular.)
- **The only thing that may leave the machine is an explicit, user-keyed (BYOK) LLM rewrite
  call** — and only after redaction has tokenized sensitive spans out of the payload.
- **Dictation is batch (commit-on-release) and inserts atomically** — one undo (⌘Z) removes
  the whole dictation.
- **No telemetry, no analytics.** Speech, transcripts, and usage are never collected.

### Non-goals
- Cross-platform (macOS-only native Swift).
- **Cloud STT** or required accounts.
- Wake-word / always-listening.
- **Silence-based auto-stop (VAD endpointing).** Evaluated and declined — few valuable use cases,
  only a saved keystroke over the existing tap-to-toggle, the premium category deliberately avoids
  it, and its natural use (long-form) fights our batch/paste model. Revisit only as an accessibility
  feature.
- File/batch transcription as a primary surface (diarization capability exists via the STT
  library, but the product is live dictation first).

---

## 2. Principles

This design is governed by `principles.md` (efficiency-as-measured-feature; no hacks /
data-driven; simple architecture; UX-first progressive disclosure; best-of-breed per
feature; consistent visual language; YAGNI; DRY; TDD red→green). Where a design choice below
leans on a principle, it is noted inline.

---

## 3. Target users

- **Primary (default experience):** privacy-conscious Mac users who want dictation that
  "just works" better than Apple's, with nothing in the cloud.
- **Secondary (power surface):** developers, writers, and heavy dictators who want modes,
  custom vocab, regex replacements, redaction, voice-editing of selected text, and optional
  BYOK LLM rewrite.

The same app serves both via progressive disclosure.

---

## 4. System architecture

```
  context: frontmost APP + URL/window title (best effort) ─┐ ranks eligible modes specificity→order
                                                │ (auto-start + which trigger phrases can route)
                                                ▼
  KEY selects its eligible mode (else Direct floor)  ─▶  INITIAL MODE  ──────────┐
                                                                                 │
  mic audio ─▶ [ pre-STT ]  ─▶  LOCAL STT ENGINE  ─▶  raw transcript             │
               (dictionary bias)   (ONE active engine — global, batch)           │
                                                │                                │
                              ┌─────────────────┴───────────────────┐           │
                              │  trigger-PHRASE routing (post-STT)   │           │
                              │  transcript suffix matches a mode's  │  switches  │
                              │  regex  →  adopt THAT mode's         │  remaining │
                              │  post-STT pipeline; strip suffix      │  pipeline ◀┘
                              └─────────────────┬───────────────────┘
                                                ▼
                          [ post-STT stages ]   live edits · replacements
                                                · numbers (ITN) · dictionary recovery
                          [ stateful stages ]   verbatim-mark · clipboard · redaction-tokenize
                                                │  (nonce tokens; local map kept)
                                                ▼
                          DYNAMIC SYSTEM PROMPT assembled from pipeline state:
                          "these dictionary terms are valid, not misspellings …" (hint)
                          "leave tokens like ⟦SN:1⟧ unchanged …" (directive)
                                                │
                        ┌───────────────────────┴───────────────────────┐
                        │            AI REWRITE (optional, BYOK)         │
            [ pre-LLM ] ─▶  cloud/local LLM (OpenAI/Anthropic/Gemini) ─▶ [ post-LLM ]
            context the mode opts into (app) + selection + fragments
                        └───────────────────────┬───────────────────────┘
                                                ▼
                          RESTORE: de-tokenize redaction/verbatim nonces
                                                ▼
                               [ insertion ]  paste (Settings default) · insert/type (TOML escapes)
                                                ▼
                                          target app field
                                                ▼
                          local history (optional) → correction surface that
                          feeds dictionary & replacements
```

### 4.1 STT abstraction (always local, one active engine)
**One STT engine is active globally.** The user picks it in settings; the whole app uses it.
The engine is resolved through a **single provider** (one source of truth, DRY) that returns the
global selection — leaving room to make resolution **mode-aware later** without touching call
sites. There is no per-mode STT (YAGNI); the seam stays clean.

**Batch, not streaming.** Most users run LLM post-processing, so live partial text is not needed:
dictation commits on key-release, then runs the pipeline. The result is inserted as **one atomic,
undoable action** (a single ⌘Z removes the entire dictation), which also covers local-only (no-LLM)
use.

**Latency budgets (perceived speed).** Batch must still *feel* instant; budgets are explicit and
measured (`principles.md` §1):
- **hotkey → recording feedback:** immediate (HUD + start sound on the same runloop turn).
- **release → local text ready:** p50/p95 per engine — a short utterance must feel instant.
- **release → cloud-rewrite ready:** p50/p95 per provider/model (the LLM is the slow leg).
- **max wait → escape hatch:** past a threshold the HUD offers "insert without rewriting," so the
  user is never stuck waiting on the cloud.

A single `SpeechEngine` interface; concrete engines (the user selects exactly one as active).
**Up to 8 curated models across 5 engine kinds** ship (`SpeechModelCatalog.all`), all with in-app
download/install except the system-managed Apple engine:
- **FluidAudio / Parakeet TDT-CTC 110M** — **default for English.** Compact (~440MB), fast and
  accurate. English only.
- **FluidAudio / Parakeet TDT v3** — larger multilingual Parakeet (25 languages), slightly
  stronger raw accuracy; **pyannote speaker diarization bundled** in the same SDK.
- **Whisper** (Large v3 Turbo via WhisperKit) — broad multilingual coverage, 99 languages.
- **Whisper Small (English)** — compact English Whisper, smaller and faster than Turbo.
- **Apple Speech** (SpeechAnalyzer, macOS 26+) — zero-install, system-managed, 20 languages. It is
  hidden on older supported macOS releases.
- **Qwen3-ASR 0.6B** — compact multilingual (52 languages); the speed/accuracy sweet spot.
- **Qwen3-ASR 1.7B** — largest multilingual model (52 languages); the strongest Qwen tier in the
  current benchmark.
- **Moonshine Base (English)** — lightweight English model; **no recognition bias** (dictionary
  recovery available in Settings).

Engines are wired through a single **`EngineRegistry`** descriptor list (catalog ↔ constructor) that
the provider, download path, install reconcile/delete, and the benchmark all derive from — adding an
engine is one descriptor + one catalog entry.

**Engine bias support.** Recognition bias is grounded in the acoustics, never a blind post-STT
find-and-replace (that silently corrupts output). Every model except Moonshine biases, each via its
model's own mechanism, all taking dictionary terms through `transcribe(wavURL:biasTerms:)`. Moonshine
has no on-device bias path and uses dictionary recovery instead:
- **Whisper** — a decode-time conditioning prompt (`promptTokens`); a soft hint the model may ignore.
- **Apple** — `AnalysisContext` contextual strings, weighted during the single decode. Requires the
  `DictationTranscriber` module — `SpeechTranscriber` silently ignores `contextualStrings`.
- **Parakeet** — FluidAudio's NeMo CTC-WS (constrained-CTC keyword spotting): TDT transcribes, then a
  same-tier CTC model re-scores dictionary terms against the acoustic frames and swaps a word only
  when CTC evidence **and** string similarity clear confidence thresholds. Acoustically grounded and
  confidence-gated. Two models (TDT v3 ↔ ctc06b, TDT-CTC 110M ↔ ctc110m); per-model tuning lives in
  `ParakeetModelProfile`. Uses the FluidAudio fork's `enableSpotterRescue` toggle (off for the weaker
  ctc110m, where the acoustic-only rescue pass false-fired).
- **Qwen3-ASR** — native on-device bias (`Qwen3DecodingOptions.context`).

Only single-pass mechanisms (Whisper, Apple, Qwen3) bias for free; Parakeet's CTC-WS runs a second
acoustic pass. Independently of the engine, the dictionary **always** feeds the post-STT LLM "valid
term" hint — so a dictionary entry is never a complete no-op even on a bias-less engine.

KeyScribe ships a **small curated list** of the best STT models, not arbitrary model selection.
Custom/other STTs are a later option; the seam stays clean (YAGNI).

**Language follows the active engine.** With one engine active globally, supported languages are
whatever that engine supports (Parakeet 25 / Whisper 99 / Apple 20 / Qwen3 52 / Moonshine 1). A user
who needs a language their engine lacks switches engines. No auto-detection or per-mode language
override.

Model lifecycle: **download → prepare (with progress) → select → delete**.

**Where weights live.** Downloaded STT weights are **consolidated under the KeyScribe support dir**
(`models/<model-id>/`, `config_schema.md`) — KeyScribe points each engine SDK at that path where the
SDK allows a custom download directory, and otherwise manages the SDK's own location through its API
for the same single disk-usage/delete story. In Application Support, not Caches, so the OS cannot
purge them mid-session; they are re-downloadable so deletion is safe and the dir is backup-excluded.
Apple SpeechAnalyzer is **system-managed** when available (no KeyScribe-side storage).

### 4.2 Command pipeline (the core)
A linear pipeline of typed stages, each declaring its **position** in the flow. Several stages are
**stateful within a single dictation** (they hold a token→original map).

| Command type | Position(s) | Purpose |
|---|---|---|
| **Dictionary** | pre-STT bias (where supported) + dynamic system-prompt | Bias recognition toward known terms via the active engine's **decode-time** mechanism (§4.1 *Engine bias support* — Whisper/Apple/Parakeet/Qwen3 yes; Moonshine no; **toggleable per engine** in the Dictionary Matching settings, see the *Dictionary recovery* row); and always hint to the LLM that those terms are valid/intentional (not misspellings). A hint, not a directive — the LLM may still transform them per the mode. |
| **Replacements** | post-STT | Heard→Replace, literal or regex with substitutions. Both match **case-insensitively** by default (the input is engine-cased STT output; a regex opts back into case with inline `(?-i)`). The result flows into the LLM normally and may be transformed by it (e.g. a "pig latin" mode). Replacements are not protected from rewrite — **except** when one rule consumes the **entire** utterance (modulo trailing whitespace/`.!?`): that "whole-utterance replacement" is inserted **verbatim and bare**, short-circuiting the LLM, redaction, `trailing`, and `trim_trailing_punctuation` (a deterministic spoken command — `slash resume`→`/resume`; see `config_schema.md` *Replacement matching & output*). A user regex is screened by **`ReplacementSafety`** before it runs: a nested-quantifier ("evil") pattern that could catastrophically backtrack on the dictation hot path is refused, not executed (there is no way to interrupt a synchronous `NSRegularExpression` match). |
| **Live edits** | post-STT | Spoken commands from a **small documented list** (*insert new line*, *insert new paragraph*, *insert tab character*, *scratch that*, *insert clipboard contents*, *begin/end verbatim* — sentence/newline-aware; the insert commands use an explicit carrier phrase, optional "a"/"the", so bare prose is left alone), **opt-in per mode** (one toggle). **"Scratch that" only fires at a clause boundary** — its phrase ends with a terminator (. ! ?) or comma, or ends the utterance — so literal use ("scratch that lottery ticket", a continuing word follows) is left as text. Matching tolerates a trailing terminator/comma; the gate is scratch-only (newline/tab fire inline). This leans on the STT punctuating a spoken correction, so a non-punctuating engine (e.g. Apple) **under-fires rather than corrupts**. **Pause-punctuation absorption:** a command is an invisible operator, so the whitespace/comma the STT hangs on its boundary when the speaker pauses is absorbed with it and re-normalized to one space (`blah, insert new line, foo` → `blah⏎foo`). Commas + whitespace only — a preceding sentence period is kept (`done. insert new paragraph next` → `done.⏎⏎next`), and verbatim content keeps its own edge terminators/`;`/`:` (`begin verbatim foo(); end verbatim` → `foo();`). Pause-agnostic: no pause → nothing to absorb → same output. |
| **Numbers (inverse text normalization)** | post-STT | Optional per-mode deterministic spoken-number → digits ("twenty five" → "25"), `commands.numbers`. Conservative by design: a run that does not form one unambiguous cardinal is left exactly as spoken (preserves year idioms like "twenty twenty six"). Wrong number output is worse than none. **Tier 1 decorators** fold in the low-ambiguity cases around a validated cardinal: sign ("minus five" → "-5", only when not preceded by a number, so subtraction is left alone), decimals ("three point one four" → "3.14"; fractional part is single digits only), percent ("fifty percent" → "50%"), and ordinals ("twenty first" → "21st"). Each decorator only fires on a cardinal that already parses and clears the standalone-small gate; anything ambiguous echoes the spoken words. **Tier 2** (currency symbols + placement, thousands grouping, dates, times) is locale/house-style/context-dependent, so it is left to the optional LLM rewrite (and skipped entirely in no-LLM modes) rather than guessed deterministically here. |
| **Dictionary recovery** | post-STT | The post-STT substitute for recognition bias: snaps mangled words to dictionary terms ("charge bee" → "ChargeBee") via the `FuzzyStage` (Levenshtein + Soundex gated; the dictionary stays a *hint*, not a protected substitution). Not a mode command — it is a **per-engine** "Dictionary Matching" setting (`settings.stt`), **decoupled from recognition bias**: each engine independently toggles recognition bias (where supported) and dictionary recovery. Defaults follow model capability — recovery **on** for engines without recognition bias, **off** for those with it (bias already recovers the terms) — but either knob is overridable per engine, so a bias-capable engine *may* run recovery and a bias-capable engine *may* have bias turned off. Persisted as deviations from the default in `recognition_bias_disabled_engines` / `dictionary_recovery_enabled_engines` / `dictionary_recovery_disabled_engines`. |
| **Verbatim** | tokenize **before** the text stages / restore last | A **live edit** (enabled by the live-edits toggle): spans delimited by spoken triggers ("begin verbatim" / "end verbatim") are pulled into a **single nonce token** **before** live edits / replacements / numbers / fuzzy run, so the span is protected from **everything except STT** (the text stages and the LLM all see only the token); restored verbatim after. Same machinery as redaction, different intent and position (protect-from-edit, first vs withhold-sensitive, last). |
| **Insert clipboard contents** | tokenize **before** the text stages / restore last | A **live edit** (same toggle): the spoken phrase "insert clipboard contents" is replaced by a **single nonce token** (its own `CLIP` type, so it can never collide with a `VERB` token when both appear in one dictation) wrapping the host-captured clipboard string — same machinery and position as Verbatim, but the token's value is external (the clipboard) rather than a delimited span. So pasted clipboard text is inserted **as-is** (character-for-character, opaque to replacements/numbers/fuzzy) and **never crosses the cloud boundary** (the LLM sees only the token) even in an AI-rewrite mode. The clipboard is read **only when the command will actually fire** (a `mentions` check, run after verbatim tokenization, gates the read — so an ordinary dictation, or a phrase deliberately wrapped in a verbatim span, never touches the clipboard), before any ⌘C/⌘V staging, as **text** (plain-text flavor, or the plain rendering of rich text via an `NSAttributedString` fallback — formatting is dropped since insertion is plain text). A **non-text clipboard** (image, copied files) or an empty clipboard yields no text, which leaves the phrase as literal words. Sorts **after** Verbatim, so a clipboard phrase inside a verbatim span stays literal. Dictation only — not edit-in-place, where the selection-capture ⌘C has already overwritten the clipboard. A pathological clipboard containing the fence sentinel (`⟦SN:…⟧`) cannot hang restore — the fixpoint is pass-capped (`Tokenizer.restore`). |
| **Privacy / redaction** | tokenize **after** the text stages / restore (+ system-prompt) | **Best-effort pattern matching** of sensitive data (API keys, PII, credit cards, …); matched spans are tokenized out of the fully-transformed text **before** the (possibly cloud) LLM and restored after. Enabled per-mode via a **privacy** toggle. Privacy mode also **forces context off** (§4.4), so the redacted transcript is the only user content that can leave the machine. |

**Stateful tokenization & restoration (verbatim / redaction).** Verbatim and redaction share one
mechanism: a span is replaced with a **nonce token carrying a type and an incrementing index** —
same value → same token within the dictation, distinct values → distinct indices (e.g.
`⟦SN:REDACT:1⟧`, `⟦SN:VERB:1⟧`, a distinctive sentinel chosen to resist LLM mangling). Verbatim is
delimited by spoken triggers ("begin verbatim" / "end verbatim") and pulls the whole chunk into a
single token. The token→original **map lives only in memory for that dictation, is never written to
history or logs**, and is applied in **reverse (LIFO)** after the LLM returns.

**Redaction is best-effort and is presented as such.** Pattern matching will miss things; the UX
never implies a guarantee. The privacy toggle and related copy say "best-effort," so KeyScribe never
creates a false sense of safety.

**Dynamic system-prompt injection.** The LLM system prompt is **assembled from pipeline state**,
not static. As stages run they contribute constraints:
- Dictionary terms present in the transcript → a hint: *"these terms are valid and intentional, not
  misspellings: …"* (the LLM may still transform them per the mode).
- Redaction/verbatim tokens present → a directive: *"leave tokens like ⟦SN:1⟧ unchanged."*
This is the mechanism that keeps tokenization and vocabulary intact through rewrite.

**Post-LLM validation gate (hard).** Token survival is enforced at runtime, not only tested. Before
restore, a deterministic gate checks the LLM output: every token KeyScribe issued returns **exactly
once** (unless the mode explicitly allows deletion), no **stray sentinel-like tokens** KeyScribe did
not issue are present, and the output is **non-empty**. On failure the rewrite is **retried once**
with a stricter minimal prompt; if it still fails, KeyScribe **falls back to the local (un-rewritten)
text** with a HUD notice and never inserts partially-restored text. A dropped redaction token would
leak the protected span; a dropped verbatim token would corrupt the insert — so this gate is a
**safety requirement**, not output normalization. Opted-in context (visible/selected text) is treated
as **untrusted data, not instructions** — kept in separate delimited blocks (`prompt_design.md`); the
gate is the cheap guardrail against context steering the rewrite or dropping tokens (indirect prompt
injection). There is no prompt-injection classifier — the deterministic checks are the guardrail that
fits the product.

#### 4.2.1 Command pattern & ordering
Each stage is a **Command object with a forward `apply` and an inverse `post`** (the token→original
maps live in the tokenizing commands). A command declares its **position** in the flow and an
**order index** within that position; the host runs every `apply` forward (position/order), then the
optional LLM + validation gate on the text, then every `post` in **strict reverse** — so a command
that tokenizes in `apply` and restores in `post` unwinds LIFO *by construction*, not by where a
restore call happens to sit. One-way text stages leave `post` at its default no-op. **Ordering is a
first-class concern — getting it wrong silently corrupts output or leaks a span**, so the canonical
order is fixed and explicit:

```
1. pre-STT        dictionary bias / system-prompt vocab seeding
2. STT            (single global engine, batch)
3. verbatim mark  verbatim tokenize · then clipboard tokenize   (apply) — BEFORE the text stages, so
                                            a verbatim span / pasted clipboard is opaque to them and
                                            to the LLM (protected from all but STT); clipboard sorts
                                            after verbatim so a clipboard phrase inside a verbatim
                                            span stays literal
4. post-STT text  live edits → replacements → numbers (ITN) → dictionary recovery   (apply)
                  (StageOrder: liveEdits 0 · replacements 10 · numbers 20 · fuzzy 30;
                   dictionary recovery is the FuzzyStage, gated by the active engine's bias capability)
5. redaction mark redaction tokenize       (apply) — AFTER the text stages, on the fully-transformed
                                            text, just before the LLM (produces nonce tokens + prompt
                                            constraints); only when privacy is on AND a rewrite runs
6. assemble       dynamic system prompt + user prompt (context blocks)
7. pre-LLM        final payload assembly
8. LLM            optional BYOK rewrite
9. post-LLM       output normalization
10. validate      HARD gate: every issued token returns exactly once; no stray ⟦SN:…⟧ KeyScribe
                  didn't issue; non-empty. Fail → one stricter retry → else local fallback + HUD.
11. restore       run every command's `post` in STRICT REVERSE of apply — redaction restored first,
                  verbatim last (LIFO). Runs on EVERY path (rewrite, fallback, and no-LLM).
12. insertion     paste (primary) / insert / type — atomic, one ⌘Z
```

Ordering rules that matter (the footguns):
- **Verbatim tokenizes FIRST (before the text stages)** — a verbatim span must be protected from
  live edits / replacements / numbers / fuzzy *and* the LLM, i.e. everything except STT. Because it
  is an opaque token before any cloud call, a secret inside a verbatim block is also shielded for free.
- **Replacements before redaction tokenization** — so redaction sees the corrected text and a
  replacement can't rewrite a redaction nonce token.
- **A whole-utterance replacement short-circuits the rest of the pipeline** — when one replacement
  rule owns the entire utterance (modulo trailing whitespace/`.!?`), the replacements stage reports
  a bare value on the `PipelineContext`; the host inserts it verbatim and skips the LLM, redaction,
  `trailing`, and `trim`. Detected **at the replacements stage** (not as a pre-pass) so it honors
  live-edits-before-replacements and freezes the value before numbers/fuzzy can mutate it. The value
  is the rule's generated output, and it only fires when re-running every rule over the utterance
  reproduces exactly that output (so a chain of rules conservatively falls through to the normal
  path). Bypassing the LLM makes redaction moot — nothing leaves the machine.
- **Redaction tokenizes LAST of the post-STT steps** — nothing after it (until restore) should mutate
  its tokens; it captures secrets in the final outbound text.
- **Restore is `post` in strict REVERSE of `apply` (LIFO)** — nested/overlapping spans unwind
  correctly, and it runs on every path including no-LLM (so verbatim markers are always stripped and
  the span restored even with no rewrite).
- Within a position, order is **explicit (index), never incidental** (DRY).

### 4.3 Modes & routing
A Mode is a **named bag of config** the generic pipeline executes. The pipeline never branches on a
mode's name or purpose (`principles.md` §2). Routing happens in two phases because some triggers are
known before speech and some only after:

**There is no separate "global hotkey."** A hotkey always belongs to a mode; the familiar Fn/Globe
key is simply the trigger key of whatever mode owns it — by default the **Direct** floor (§4.3).
What users informally call "the global hotkey" is just that Fn binding.

**Phase A — known before STT (full pipeline available):**
- **Trigger key(s):** press styles are **hold-or-tap** (push-to-talk while held *or* fires on a quick
  tap), **hold-only**, and **tap-to-toggle**. A key **selects its mode** as the initial mode and runs
  that mode's *entire* pipeline including pre-STT bias. A key only selects a mode that is **eligible in
  the current context** (its constraints match): pressing a key bound to a Slack-only mode while in
  Slack runs it; pressing it elsewhere does **not** — an app constraint scopes the mode for *every*
  trigger, not just automatic selection. When **several modes share the key**, the eligible bound mode
  whose constraints best fit wins (most specific, then declaration order), with an unconstrained bound
  mode as the fallback — so one key can drive a Slack-only mode in Slack and a plain mode everywhere
  else. **A press is never a no-op and never silently borrows a different configured mode:** when no
  bound mode is eligible here, the key falls through to the **Direct** floor (see below) — a plain,
  on-device dictation. (The STT *engine* is global — modes do not pick it; see §4.1.) Any key is
  **capturable** — the **recommended default is Fn/Globe with hold-or-tap**, bound to Direct,
  with **right-Option** as a conflict-free alternative. Holding **Hyper** (⌃⌥⇧⌘) can be a trigger.
  Conflicts with system/other-app shortcuts are handled **best-effort** (detect and warn at
  assignment).
- **Context constraints (`bundle_id` / `bundle_prefix` / `url_pattern` / `window_title`):** the
  frontmost app, and the URL / window title when detectable, are identified **best-effort** to **gate
  and rank the eligible modes** in that context. A constraint ANDs all of its fields. A constraint
  **gates** the mode (it cannot run outside its context, by key *or* voice) and, among eligible modes,
  **ranks** them. The eligible set bounds both the key press and Phase-B voice routing. The one
  deliberate escape hatch is the menu: picking a mode by name runs it regardless of context. (`url_pattern`
  needs an Automation prompt and `window_title` an extra AX read, so each is probed only when some
  enabled mode actually uses it.)

**Mode resolution (one resolver, both phases).** When no key is pressed, Phase A picks the initial
mode; when a transcript suffix matches, Phase B picks the routed-to mode. Both use the **same rule
over the eligible (context-allowed) modes: specificity first, then declaration order.** A constraint
scores by summing the narrowness of each present field — **`url_pattern`=4 > `window_title`=3 >
`bundle_id`=2 > `bundle_prefix`=1** — so fields combine (`bundle_id`+`url_pattern`=6 beats
`url_pattern` alone=4) and a mode constrained to the *current* context outranks a less-constrained
one; an **unconstrained** mode is the least specific (0). Equal specificity breaks by the mode list's
declaration order. Only **constrained** modes auto-start in Phase A; if none match, resolution falls
to the **Direct** floor. There is **no separate "default mode"** — Direct *is* the single catch-all
(it owns Fn out of the box) and what every unmatched trigger lands on. Unconstrained modes never
auto-start — they are reachable by **key or voice only**. When a key is pressed but **no mode bound
to it is eligible here**, the press also falls to Direct — it still dictates, just plainly.

**Phase B — known only after STT (trigger-phrase routing):**
- **Trigger phrase(s):** a mode may have **multiple** spoken phrases (e.g. *"as pig latin"*
  or *"pig latinize"* both route to the same mode). Because they depend on STT output they **cannot
  run pre-STT**. A phrase is matched at the **end** of the transcript — case-insensitively, on a word
  boundary, and after trailing punctuation/whitespace that STT appends is trimmed — so a bare phrase
  routes without any regex syntax; each phrase is also a regex for power users (`(?-i)` opts back into
  case-sensitivity). If the transcript suffix matches an eligible mode's phrase, KeyScribe **adopts
  that mode's remaining post-STT pipeline** and strips the matched suffix (raw-suffix routing). When
  several eligible modes match the same suffix, the **specificity → declaration-order** rule above
  picks the winner.
- **Routing adopts only the *post-STT* pipeline.** The base mode's pre-STT stages already ran and are
  not redone; the routed-to mode's pre-STT stage (dictionary **recognition bias**, the only pre-STT
  stage) **never applies on a voice route** — recognition bias is fixed at STT time from the Phase-A
  mode, before the suffix that triggers a Phase-B route is even transcribed. So a voice-routed mode
  forgoes only its *own* dictionary's recognition-bias contribution; its dictionary still feeds the
  post-STT LLM "valid term" hint. An edge case worth knowing, not a correctness concern.

Each mode also carries:
- **Dictionary & replacements** of its own, and may optionally **exclude the global**
  dictionary/replacements.
- **Privacy toggle** — when on, best-effort redaction (§4.2) runs for this mode, and **context is
  disabled and prevented** for the mode (§4.4): the context checkboxes are forced off and locked, so
  no app/selection text can be sent to the cloud alongside the transcript. Redaction therefore
  only has to cover the transcript.
- **Live-edits opt-in** — whether the spoken command list (insert new line, insert new paragraph,
  insert tab character, scratch that, insert clipboard contents, begin/end verbatim) is active for
  this mode.
- **Context opt-in** — checkboxes for what to send to the LLM: **App** and **preceding text**
  (bounded text before the caret, native-only/best-effort) (§4.4). (The URL is a routing key only,
  never sent — §4.3.)
- **Shared prompt fragments** — named, reusable snippets **appended** to the mode's prompt (e.g. a
  "my voice" fragment shared across email and Slack modes). Appended in order, kept simple.
- Optional **AI rewrite** (a **named LLM connection** + prompt + fragments + opted-in context).
- **Insertion method**; **exclude-from-history**.

**The Direct floor (there is no separate "default mode").** The **Direct** floor (id `_direct`,
**shown to users as "Plain Dictation"** — "Direct" is the internal name) is the single always-available
floor: it **owns Fn/Globe out of the box** and is what every unmatched trigger — a key whose bound
modes aren't eligible here, or a no-key/no-context start — lands on. There is deliberately **no second
"default mode" designation**: a configurable everyday default plus a locked floor was two competing
catch-alls (and a constrained default could itself fail to match and drop to the floor — confusing),
so they are merged into Direct. The everyday mode is simply *whatever you bind to Fn* — Direct by
default; bind a different mode there to change it.

Direct is a **guaranteed minimal recipe** that can never be deleted, duplicated, made-default, or
misconfigured to leak: **never an LLM rewrite, never context, never edit-in-place, no vocabulary of
its own** (it relies on the **global** dictionary for recognition bias and **global** replacements).
A few fields *are* user-editable — its **trigger key**, insertion method, trailing/submit, live-edits,
and whether it **records to history** (it records per the global History setting by default; you can
switch that off for Direct specifically). It occupies a reserved **system-mode id namespace** (a
leading underscore, `_direct`) that the mode-name slugger can never produce, so a user-created mode can
never collide with it; locked fields are re-enforced on load so a hand-edit can't weaken the floor. The
recording HUD shows **Plain Dictation** while it runs, so a fallthrough is honest, not silent. This
makes a key press a two-part promise: a constrained mode scopes only its *processing*, never your
*ability to dictate* — when the recipe does not apply here, the floor still types your words.

**Shared-key limitation.** When two modes own the same physical key (e.g. Plain Dictation and an
app-scoped mode both on Fn — the intended "context disambiguates" workflow), the resolver still picks
the right mode by context, but the *gesture* (press style: hold-or-tap / hold-only / tap-to-toggle) is
shared: one physical key has one interpretation, taken from the higher-precedence mode (Plain Dictation
leads, since system/declaration order). A shared key can't have two press styles at once — this is
inherent, not a routing bug.

**Edit-in-place is a capability, not a magic mode.** There is no special "edit selection" mode — any
mode can be configured this way. The flow:
1. user **selects text** in the target app,
2. presses the **mode-specific key**,
3. **dictates transformation instructions**,
4. the mode combines its **prompt + the transcribed instructions + the selected text** and the LLM
   produces the result, which **overwrites the selection**.

This requires a reliable **"copy selected text" capability**. Synthesized **⌘C → read pasteboard is
the universal method** (works in Electron/Chromium/native); AX `kAXSelectedText` is a **native-only**
enhancement (empty on Electron/Chromium), so ⌘C-copy is the primary path and AX a bonus where
present. It is the one case that bends the Mode model (input is selection+voice, output overwrites),
but it stays a configured mode, not an engine fork.

### 4.4 AI rewrite context
A mode **opts into** the context it sends to the LLM via checkboxes — **App** and **preceding text**
(a bounded amount of text immediately before the caret, native-only and best-effort) — plus the
current selection when it is an edit-in-place mode. Nothing is sent that the mode did not opt into.
Optional, BYOK, and only over redacted payloads.

**The URL is never sent to the LLM.** It is a *local* routing key only (`url_pattern`, §4.3): matched
against a regex on-device to rank modes, never transmitted. As rewrite context it adds little over
the app identity while disproportionately widening the cloud payload — URLs routinely embed session
tokens, record ids, and search queries the user never sees. So URL is scoped to routing; app identity
and preceding text are the only situational context channels.

The frontmost **app/bundle id is always available**. (Browser **URL detection** — AppleScript/Apple
Events per browser, not AX — feeds `url_pattern` only, §4.3/§4.5.)

**Privacy mode forces context off.** When a mode's privacy toggle is on (§4.3), the context
checkboxes are **disabled and locked off** — visible/app/selection text is never attached. This is
the deliberate resolution to the payload-leak problem: rather than run redaction over large untrusted
context blocks (and miss things, best-effort), privacy mode simply **prevents context from leaving at
all**, so the redacted transcript is the only user content in the cloud payload. Context-aware
rewrite and privacy are therefore mutually exclusive per mode by design.

- Opted-in context chunks are appended as **fixed, clearly-delimited blocks** in a stable order,
  alongside the mode's prompt and shared fragments. Prompt + system-prompt structure is designed in
  `prompt_design.md`. (User-defined prompt templating that places chunks at arbitrary points is a
  confusing footgun — out of scope, YAGNI.)
- **LLM floor: Gemini 2.5 Flash.** The lowest-common-denominator target. Prompt structure is tuned
  to be reliable on a fast/cheap model — explicit, well-delimited, concise — not dependent on
  top-tier instruction-following.

### 4.5 Insertion
**Paste is the primary method and the Settings behavior.** Paste lands text across
Electron/Chromium/native and **undoes in a single ⌘Z**. **AX-insert and type are unreliable** (no
visible insert in several apps; some apps also intercept the keystrokes), so they remain TOML-only
compatibility escapes for the few targets that benefit (Settings treatment in `config_schema.md`).
AX-insert sets the focused element's
selected text but **does not trust the API's `.success` return** — Chromium/Electron return success
and silently no-op it. It only takes the AX path when it can read the field value back and confirm it
changed, else **falls back to paste** — so `insert` uses AX on native fields and paste on
web/Electron and never loses text. Type posts Unicode key events with no success signal, so it is
best-effort with no fallback. The focus-race clipboard fallback (below) overrides whichever method
the mode picks.
- **Permissions:** **two** TCC categories — **Accessibility** (post ⌘V/⌘C and AX reads;
  `kTCCServicePostEvent` for posting, `kTCCServiceAccessibility` for AX, both shown under
  "Accessibility") **and** the modifier-only trigger event tap (an active `.defaultTap` watching
  `flagsChanged` is authorized by Accessibility alone) — plus **Automation/Apple Events** (browser
  URL via AppleScript, per browser). **Input Monitoring is NOT used:** key+modifier chord triggers
  register via `RegisterEventHotKey` (no permission, OS-suppressed) and ESC-to-cancel is a local
  keystroke on the recording HUD. A CGEventTap is deaf to `keyDown` without Input Monitoring, so it
  only ever watches modifiers.
- **Principle:** minimize the permission surface. Prefer paste; do **not** require AX-insert if it is
  the *only* reason to ask for a permission. Request **Automation** only when a mode constrains by URL
  (`url_pattern` routing, §4.3).

**Target capture & focus race.** The target (frontmost app, focused element if AX exposes it, and a
selection snapshot) is captured **at trigger time**. Because batch + LLM rewrite takes seconds, focus
may move before insertion. KeyScribe verifies best-effort at insert: app/focus change is reliably
detectable; **field-level** change is detectable on native apps but often **only app-level on
Electron**. On mismatch or uncertainty, it **falls back to the clipboard** and a HUD notice rather
than risk inserting in the wrong place.
- **Paste last dictation** — a command to paste the most recent result on demand (the universal
  fallback).
- **Serialized dictations** — a new dictation is queued or rejected while one is still processing; no
  overlapping insertions.

### 4.6 Settings
- **General:** load on login; **STT model eviction** (Fastest = keep loaded, no eviction; Balanced =
  evict after an idle timer; Frugal = evict after each dictation); during-dictation (mute system
  audio, keep display awake, sound on start/end); local history; optional correction-panel shortcuts.
- **Speech models:** download/select/delete.
- **Vocabulary:** global Dictionary & Replacements.
- **AI Services (BYOK):** **named LLM connections** — each a `(name, provider, model, auth method,
  params)`. Hosted providers use a `key_ref` into Keychain. OpenAI-compatible endpoints additionally
  support no auth for local/no-auth servers or a token command that mints a bearer token on demand;
  generated tokens are cached in memory only and never persisted. Modes reference a connection by
  name; multiple connections allowed.
- **Modes:** a focused mode editor for common behavior plus read-only notes for advanced TOML-only
  behavior; each mode persists as a **TOML** file. Schema and the referenced config files are
  specified in `config_schema.md`.

The settings information architecture, progressive-help contract, and control behavior are normative
in `ui_design.md` and `ui_components.md`.

### 4.7 Local history
Optional, **on-device only** (a **`history/` directory with one JSONL file per day**, append-only),
never synced. A **simple retention policy** bounds it (delete day-files older than N days, or cap
entries). Per-mode "exclude from history." Password-field dictations are never written to history,
regardless of the global or per-mode setting.

**Stored per entry:** raw transcription, the mode used, the **exact prompt sent to the LLM**, and the
**final text pasted/inserted**. History can be searched, summarized, and exported as Markdown, plain
text, or JSONL. **Audio is never stored.** The stored prompt carries the **tokens**
(⟦SN:…⟧), not their originals — the **redaction map is never stored** — but the raw transcription and
final insert do contain the real values, so for sensitive work the lever is **disabling history** for
that app/mode (per-mode "exclude from history").

**History is also a correction surface:** from a history entry the user can quickly define a
**replacement** or **dictionary** entry to fix what was misheard — the common "that came out wrong,
never again" loop.

A **standalone correction panel** also covers this fast loop outside History: a global shortcut (or
the menu's **Add to Vocabulary…**) opens a small vocabulary panel with stacked
**Word or heard phrase** and **Use instead (optional)** fields. Leaving **Use instead** empty saves a
dictionary term; filling it in saves a global replacement. Turning on regex makes this
replacement-only and requires **Use instead**, avoiding an ambiguous empty replacement. The first
field is **pre-filled from the current selection** when text is selected in the target app. Once a
replacement value is entered, the panel offers **Add & Replace Selection** so the saved correction can
also fix the currently selected text.

### 4.8 Dictation feedback
- **Sound** on dictation start and end.
- **Floating HUD** — small, clear, and **movable** on screen. Shows a **live voice indicator** (input
  level), **whether the cloud is involved** (a BYOK LLM rewrite is part of this dictation), and a
  processing state while the LLM runs. Consistent with the visual language (`principles.md` §6).

HUD states, data-boundary wording, and fallback behavior are normative in `ui_design.md`.

### 4.9 First-run & onboarding
- **Progressive permissions** — request the minimum to start (dictation + paste); ask for
  context-reading only when a feature that needs it is enabled.
- **Seeded example modes** — first launch installs a few helpful example modes so the value is
  immediate and the user has working templates to learn from. Examples demonstrate generic
  capabilities, not hardcoded app identities (`config_schema.md`).

---

## 5. Technology choices

- **Language/UI:** Swift + SwiftUI (menu-bar app, settings window). Native for perf, accessibility
  APIs, and optional Apple SpeechAnalyzer access on macOS 26+.
- **STT:** **FluidAudio** (Parakeet TDT v3 + pyannote diarization, CoreML/ANE); **WhisperKit** for
  Whisper; system `SpeechAnalyzer` for Apple; **speech-swift / Qwen3ASR** (MLX) for Qwen3-ASR;
  **moonshine-swift** (ONNX) for Moonshine. (Fork/pin details in `AGENTS.md`.)
- **Audio:** AVAudioEngine for capture; system-audio muting via Core Audio.
- **Global hotkeys / insertion:** CGEvent (`kTCCServicePostEvent`) for paste keystroke; Accessibility
  (`kTCCServiceAccessibility`) for context reading and optional AX insert; `RegisterEventHotKey`
  (Carbon) for chord triggers.
- **LLM:** thin BYOK client over OpenAI/Anthropic/Gemini/OpenAI-compatible HTTP APIs; hosted-provider
  keys in Keychain; OpenAI-compatible endpoints can use no auth, a Keychain-backed bearer token, or
  a command-generated bearer token cached in memory until its expiry/default TTL.
- **Storage (file-based, no DB):**
  - **Modes → TOML files** (one per mode) — human-readable, hand-editable, diff-friendly, naturally
    data-driven (`principles.md` §2).
  - **History → `history/` directory, one JSONL file per day** (append-only) — greppable, streamable;
    retention drops old day-files.
  - **Global dictionary & replacements → TOML.**
  - **Shared prompt fragments → `fragments/` directory, markdown + YAML frontmatter.**
  - **LLM connections → TOML** (key material in Keychain, referenced by id; command-generated
    tokens in memory only).
  - **STT weights → `models/` dir** under the support root (runtime-downloaded, never committed,
    backup-excluded; §4.1).
  - **Redaction/verbatim maps → in-memory only**, never persisted.
  - No SQLite (simple architecture, YAGNI). Revisit only if history search outgrows line-scanning
    JSONL.
- **Distribution & updates:** direct distribution, **notarized** (Developer ID) — **not** Mac App
  Store, whose App Sandbox restricts the AX APIs KeyScribe depends on. **In-app updates** (Sparkle)
  with a menu-bar indicator are planned, not built.
- **License: GPLv3.** Compatible with the deps (Apache-2.0 and MIT code flow into a GPLv3 project;
  weights are runtime-downloaded *data*, not linked code, so the source tree stays clean), and it
  permits selling notarized binaries provided source is offered. The legal obligation is four things:
  (1) a GPLv3 `LICENSE`; (2) a `THIRD-PARTY-NOTICES.md` with the Whisper/FluidAudio/Parakeet/pyannote/
  Qwen3/Moonshine attributions; (3) **CC-BY-4.0 attribution surfaced in-app** (a credits/notices
  screen) for Parakeet weights and pyannote — CC-BY requires visible attribution; (4) weights
  downloaded at runtime, never committed. No CLA.

### 5.1 Config schema versioning & migration
Every persisted config file (**modes, LLM connections, dictionary/replacements, general settings**)
carries a **`schema_version`**.
- On load, files below the current version are upgraded through an **ordered, forward-only migration
  chain** (v1 → v2 → …) and rewritten. Each file type owns its own version and migration steps, run by
  **one shared migration runner** (DRY).
- A file from a **newer** version than the app understands is **not silently downgraded** — the app
  surfaces it and leaves it untouched.
- A **pre-migration backup** is written so a failed or unwanted migration is recoverable.
- User-editable files are **validated** on load; invalid files surface a clear error rather than being
  silently dropped.
- **Last-known-good recovery (modes):** every clean mode decode is copied to a recovery store
  (`<support>/lkg/modes/`, outside the watched tree). A malformed mode file falls back to its prior
  good copy — in-memory first, then the disk copy when memory has nothing (the file was already
  malformed **at launch**) — so one bad hand edit never makes a mode disappear. Recovery is reported,
  never silent; a re-seed/reset clears the store so it cannot resurrect a removed mode.
- **Seed reconcile (modes):** schema versioning above upgrades a file's *format*; seed reconcile
  separately carries the **seeded starter catalog** forward as it drifts (renames, new starters, prompt
  revisions) without clobbering edits or resurrecting deletions. It is driven by a **seed ledger**
  (`<support>/lkg/seed-ledger.toml`, beside the LKG store and cleared by the same reset) keyed on a
  **template fingerprint** that excludes the `connection`/`enabled` user-knobs — so a starter the user
  merely connected still matches and stays eligible for an update; only a real template edit diverges.
  Every step fails safe (a wrong guess only ever *skips* a change, never clobbers) and the pass is
  idempotent. Revising a starter's template **requires bumping its
  `seed_version`** — the only signal that carries the change to existing installs. Full step semantics
  (rename / additive / re-baseline / update, ledger bootstrap, deletion honoring) in `config_schema.md`.

---

## 6. Differentiation summary (vs `competitors.md`)

| Capability | KeyScribe | Superwhisper | Wispr Flow | VoiceInk | Apple |
|---|---|---|---|---|---|
| STT always local (no cloud STT) | ✅ | ✅ (opt) | ❌ cloud | ✅ | ✅ |
| Pluggable engines | ✅ 8 | ✅ 2 | ❌ | ✅ 1 | n/a |
| Per-context modes (data-driven) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Staged pipeline (pre/post STT+LLM) | ✅ **unique** | partial | ❌ | ❌ | ❌ |
| Redaction + restoration (cloud-safe) | ✅ **unique** | ❌ | ❌ | ❌ | ❌ |
| Dynamic, state-driven system prompt | ✅ **unique** | ❌ | ❌ | ❌ | ❌ |
| Voice-edit selected text | ✅ | partial | ✅ | ❌ | ❌ |
| BYOK rewrite | ✅ | ✅ | ❌ | ✅ (opt) | ❌ |
| Simple default UX | ✅ goal | ⚠️ complex | ✅ | ⚠️ | ✅ |
