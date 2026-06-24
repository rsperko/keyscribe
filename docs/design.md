# KeyScribe — High-Level Design

> Status: initial design draft (June 2026). Derived from `initial_scratch_notes/scratch_pad.md`
> and the competitive survey in `competitors.md`. Governed by `principles.md`.
> This is a living document.
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
result — and because that step *can* be cloud, redaction is what lets you use it safely:
sensitive content is tokenized out before it leaves the machine and restored after.

### Positioning in one line
> *"Apple Dictation's simplicity, Superwhisper's power, and a privacy story neither cloud
> tool can match — STT always local, sensitive data tokenized before any optional cloud
> rewrite."*

### The wedge
1. **Privacy-first, simple** — STT is always local; the default experience is clean and
   unintimidating. Redaction + restoration make even cloud LLM rewrite privacy-safe.
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
- **No telemetry, no analytics.** Speech, transcripts, and usage are never collected. Crash
  reporting, if present, is **opt-in only and scrubbed**.

### Non-goals for v1
- Cross-platform (macOS-only native Swift; portability is a later question).
- **Cloud STT** or required accounts.
- Wake-word / always-listening.
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
  context: frontmost APP + URL (best effort)  ──┐ ranks eligible modes specificity→order
                                                │ (auto-start + which trigger phrases can route)
                                                ▼
  KEY forces its mode / context  ─▶  INITIAL MODE  ─────────────────────────────┐
                                                                                 │
  mic audio ─▶ [ pre-STT ]  ─▶  LOCAL STT ENGINE  ─▶  raw transcript             │
               (dictionary bias)   (ONE active: FluidAudio/Parakeet              │
                                    · Whisper · Apple — global, batch)           │
                                                │                                │
                              ┌─────────────────┴───────────────────┐           │
                              │  trigger-PHRASE routing (post-STT)   │           │
                              │  transcript suffix matches a mode's  │  switches  │
                              │  regex  →  adopt THAT mode's         │  remaining │
                              │  post-STT pipeline; strip suffix      │  pipeline ◀┘
                              └─────────────────┬───────────────────┘
                                                ▼
                          [ post-STT stages ]   live edits · replacements
                                                · numbers (ITN) · fuzzy correction
                          [ stateful stages ]   verbatim-mark · redaction-tokenize
                                                │  (nonce tokens; local map kept)
                                                ▼
                          DYNAMIC SYSTEM PROMPT assembled from pipeline state:
                          "these dictionary terms are valid, not misspellings …" (hint)
                          "leave tokens like ⟦SN:1⟧ unchanged …" (directive)
                                                │
                        ┌───────────────────────┴───────────────────────┐
                        │            AI REWRITE (optional, BYOK)         │
            [ pre-LLM ] ─▶  cloud/local LLM (OpenAI/Anthropic/Gemini) ─▶ [ post-LLM ]
            context the mode opts into (app, visible text) + selection + fragments
                        └───────────────────────┬───────────────────────┘
                                                ▼
                          RESTORE: de-tokenize redaction/verbatim nonces
                                                ▼
                               [ insertion ]  paste (primary) · insert · type
                                                ▼
                                          target app field
                                                ▼
                          local history (optional) → correction surface that
                          feeds dictionary & replacements
```

### 4.1 STT abstraction (always local, one active engine)
**One STT engine is active globally.** The user picks it in settings; the whole app uses it.
The engine is resolved through a **single provider** (one source of truth, DRY) that today
returns the global selection — which leaves room to make resolution **mode-aware later**
without touching call sites. We do **not** build per-mode STT now (YAGNI); we just keep the
seam clean.

**Batch, not streaming.** Most users will run LLM post-processing, so live partial text is
not needed for v1: dictation commits on key-release, then runs the pipeline. The result is
inserted as **one atomic, undoable action** (a single ⌘Z removes the entire dictation), which
also covers local-only (no-LLM) use.

**Latency budgets (perceived speed).** Batch must still *feel* instant; budgets are explicit and
measured (`principles.md` §1):
- **hotkey → recording feedback:** immediate (HUD + start sound on the same runloop turn).
- **release → local text ready:** p50/p95 targets per engine — a short utterance must feel instant.
- **release → cloud-rewrite ready:** p50/p95 per provider/model (the LLM is the slow leg).
- **max wait → escape hatch:** past a threshold the HUD offers "paste local transcript now," so
  the user is never stuck waiting on the cloud.
A non-inserted **local-transcript preview** in the HUD while cloud rewrite runs is a candidate
(keeps atomic insertion while cutting the felt wait) — considered, not committed for v1.

A single `SpeechEngine` interface; concrete engines (the user selects exactly one as active).
v1 ships **7 curated models across 5 engine kinds** (`SpeechModelCatalog.all`); all run live with
in-app download/install:
- **FluidAudio / Parakeet TDT-CTC 110M** — **default for English.** Compact (~440MB), fast and
  accurate. English only.
- **FluidAudio / Parakeet TDT v3** — larger multilingual Parakeet (25 languages), slightly
  stronger raw accuracy; **pyannote speaker diarization bundled** in the same SDK.
- **Whisper** (Large v3 Turbo via WhisperKit) — broad multilingual coverage, 99 languages.
- **Apple Speech** (SpeechAnalyzer, macOS Tahoe) — zero-install, system-managed, 20 languages.
- **Qwen3-ASR 0.6B** — compact multilingual (52 languages); the speed/accuracy sweet spot in our
  benchmarks.
- **Qwen3-ASR 1.7B** — largest multilingual model (52 languages); the benchmark WER winner.
- **Moonshine Base (English)** — lightweight English model; **no dictionary bias** (bias-exempt,
  badged in Settings).

Engines are wired through a single **`EngineRegistry`** descriptor list (catalog ↔ constructor) that
the provider, download path, install reconcile/delete, and the benchmark all derive from — adding an
engine is one descriptor + one catalog entry.

**Engine bias support.** Recognition bias must be grounded in the acoustics, never a blind post-STT
find-and-replace (that silently corrupts output). Six of the seven models bias, each via its model's
own mechanism, and all take dictionary terms through `transcribe(wavURL:biasTerms:)` (Moonshine is
the exception — no on-device bias path):
- **Whisper** — a decode-time conditioning prompt (`promptTokens`); a soft hint the model may ignore.
- **Apple** — `AnalysisContext` contextual strings, weighted during the single decode. Requires the
  `DictationTranscriber` module — `SpeechTranscriber` silently ignores `contextualStrings`.
- **Parakeet** — FluidAudio's NeMo CTC-WS (constrained-CTC keyword spotting): TDT transcribes, then a
  same-tier CTC model re-scores dictionary terms against the acoustic frames and swaps a word only
  when CTC evidence **and** string similarity clear confidence thresholds. This is acoustically
  grounded and confidence-gated — not the old blind span substitution (`Yeah`→`Bayes`) that was
  removed. Two models (TDT v3 ↔ ctc06b, TDT-CTC 110M ↔ ctc110m); per-model tuning lives in
  `ParakeetModelProfile`. Needs our FluidAudio fork's `enableSpotterRescue` toggle (off for the weaker
  ctc110m, where the acoustic-only rescue pass false-fired).

Only single-pass mechanisms (Whisper, Apple) bias for free; Parakeet's CTC-WS runs a second acoustic
pass. There is no capability-flag type (an earlier `EngineCapabilities` seam was unused and removed).
Independently of the engine, the dictionary **always** feeds the post-STT LLM "valid term" hint — so a
dictionary entry is never a complete no-op even on Parakeet.

**v1 ships a small curated list of the best STT models** — not arbitrary model selection.
Letting users specify other/custom STTs is a later option; the seam stays clean (YAGNI).

**Language follows the active engine.** With one engine active globally, supported languages
are whatever that engine supports (Parakeet 25 / Whisper 99 / Apple 20). A user who needs a
language their engine lacks switches engines. No auto-detection or per-mode language override
in v1.

Model lifecycle: **download → compile (with progress) → select → delete**, per scratch pad.
Library choice follows best-of-breed (`principles.md` §5); FluidAudio is the current pick.

**Where weights live.** Downloaded STT weights are **consolidated under the KeyScribe support dir**
(`models/<model-id>/`, `config_schema.md`) — KeyScribe points each engine SDK at that path where the
SDK allows a custom download directory, and otherwise manages the SDK's own location through its
API for the same single disk-usage/delete story. In Application Support, not Caches, so the OS
cannot purge them mid-session; they are re-downloadable so deletion is safe and the dir is
backup-excluded. Apple SpeechAnalyzer is **system-managed** (no KeyScribe-side storage).

### 4.2 Command pipeline (the core)
A linear pipeline of typed stages, each declaring its **position** in the flow. Several
stages are **stateful within a single dictation** (they hold a token→original map).

| Command type | Position(s) | Purpose |
|---|---|---|
| **Dictionary** | pre-STT bias (where supported) + dynamic system-prompt | Bias recognition toward known terms via the active engine's **decode-time** mechanism (§4.1 *Engine bias support* — Whisper/Apple/Parakeet yes; Moonshine no); and always hint to the LLM that those terms are valid/intentional (not misspellings). A hint, not a directive — the LLM may still transform them per the mode. |
| **Replacements** | post-STT | Heard→Replace, literal or regex with substitutions. The result flows into the LLM normally and may be transformed by it (e.g. a "pig latin" mode). Replacements are not protected from rewrite. A user regex is screened by **`ReplacementSafety`** before it runs: a nested-quantifier ("evil") pattern that could catastrophically backtrack on the dictation hot path is refused, not executed (there is no way to interrupt a synchronous `NSRegularExpression` match). |
| **Live edits** | post-STT | Spoken commands from a **small documented list** (*new line*, *paragraph*, *scratch that*, *tab*, *begin/end verbatim* — sentence/newline-aware), **opt-in per mode** (one toggle). **"Scratch that" only fires at a clause boundary** — its phrase ends with a terminator (. ! ?) or comma, or ends the utterance — so literal use ("scratch that lottery ticket", a continuing word follows) is left as text. Matching tolerates a trailing terminator/comma; the gate is scratch-only (newline/tab fire inline). This leans on the STT punctuating a spoken correction, so a non-punctuating engine (e.g. Apple) **under-fires rather than corrupts**. Custom trigger words and an escape mechanism come later. |
| **Numbers (inverse text normalization)** | post-STT | Optional per-mode deterministic spoken-number → digits ("twenty five" → "25"), `commands.numbers`. Conservative by design: a run that does not form one unambiguous cardinal is left exactly as spoken (preserves year idioms like "twenty twenty six"). Wrong number output is worse than none. **Tier 1 decorators** fold in the low-ambiguity, locale-light cases around a validated cardinal: sign ("minus five" → "-5", only when not preceded by a number, so subtraction is left alone), decimals ("three point one four" → "3.14"; fractional part is single digits only), percent ("fifty percent" → "50%"), and ordinals ("twenty first" → "21st"). Each decorator only fires on a cardinal that already parses and clears the standalone-small gate; anything ambiguous echoes the spoken words. **Tier 2 (deferred — LLM/mode territory, not this stage):** currency symbols + placement ("$20.50"), thousands grouping ("5,200"), dates, and times are locale/house-style/context-dependent, so they are left to the optional LLM rewrite (and skipped entirely in no-LLM modes) rather than guessed deterministically here. |
| **Fuzzy correction** | post-STT | Optional per-mode snap of mangled words to dictionary terms ("charge bee" → "ChargeBee"), `commands.fuzzy_correction`. Conservative (Levenshtein + Soundex gated); the dictionary stays a *hint*, not a protected substitution. Bias-less engines (Moonshine) benefit most. |
| **Verbatim** | tokenize **before** the text stages / restore last | A **live edit** (enabled by the live-edits toggle): spans delimited by spoken triggers ("begin verbatim" / "end verbatim") are pulled into a **single nonce token** **before** live edits / replacements / numbers / fuzzy run, so the span is protected from **everything except STT** (the text stages and the LLM all see only the token); restored verbatim after. Same machinery as redaction, different intent and position (protect-from-edit, first vs withhold-sensitive, last). |
| **Privacy / redaction** | tokenize **after** the text stages / restore (+ system-prompt) | **Best-effort pattern matching** of sensitive data (API keys, PII, credit cards, …); matched spans are tokenized out of the fully-transformed text **before** the (possibly cloud) LLM and restored after. Enabled per-mode via a **privacy** toggle. Privacy mode also **forces context off** (§4.4), so the redacted transcript is the only user content that can leave the machine. |

**Stateful tokenization & restoration (verbatim / redaction).** Verbatim and redaction share
one mechanism: a span is replaced with a **nonce token carrying a type and an incrementing
index** — same value → same token within the dictation, distinct values → distinct indices
(e.g. `⟦SN:REDACT:1⟧`, `⟦SN:VERB:1⟧`, a distinctive sentinel chosen to resist LLM mangling).
Verbatim is delimited by spoken triggers ("begin verbatim" / "end verbatim") and pulls the
whole chunk into a single token. The token→original **map lives only in memory for that
dictation, is never written to history or logs**, and is applied in **reverse (LIFO)** after
the LLM returns. (Convention per reversible-tokenization best practice — see `competitors.md`
sources.)

**Redaction is best-effort and is presented as such.** Pattern matching will miss things; the
UX never implies a guarantee. The privacy toggle and any related copy say "best-effort," so we
never create a false sense of safety.

**Dynamic system-prompt injection.** The LLM system prompt is **assembled from pipeline
state**, not static. As stages run they contribute constraints:
- Dictionary terms present in the transcript → a hint: *"these terms are valid and
  intentional, not misspellings: …"* (the LLM may still transform them per the mode).
- Redaction/verbatim tokens present → a directive: *"leave tokens like ⟦SN:1⟧ unchanged."*
This is the mechanism that keeps tokenization and vocabulary intact through rewrite.

**Post-LLM validation gate (hard).** Token survival is enforced at runtime, not only tested.
Before restore, a deterministic gate checks the LLM output: every token KeyScribe issued returns
**exactly once** (unless the mode explicitly allows deletion), no **stray sentinel-like tokens**
KeyScribe did not issue are present, and the output is **non-empty**. On failure the rewrite is
**retried once** with a stricter minimal prompt; if it still fails, KeyScribe **falls back to the
local (un-rewritten) text** with a HUD notice and never inserts partially-restored text. A
dropped redaction token would leak the protected span; a dropped verbatim token would corrupt
the insert — so this gate is a **safety requirement**, not output normalization. Opted-in
context (visible/selected text) is treated as **untrusted data, not instructions** — kept in
separate delimited blocks (`prompt_design.md`); the gate is the cheap guardrail against context
steering the rewrite or dropping tokens (indirect prompt injection). No prompt-injection
classifier in v1 — the deterministic checks are the guardrail that fits the product.

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
3. verbatim mark  verbatim tokenize        (apply) — BEFORE the text stages, so a verbatim span is
                                            opaque to them and to the LLM (protected from all but STT)
4. post-STT text  live edits → replacements → numbers (ITN) → fuzzy correction   (apply)
                  (StageOrder: liveEdits 0 · replacements 10 · numbers 20 · fuzzy 30)
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
- **Redaction tokenizes LAST of the post-STT steps** — nothing after it (until restore) should mutate
  its tokens; it captures secrets in the final outbound text.
- **Restore is `post` in strict REVERSE of `apply` (LIFO)** — nested/overlapping spans unwind
  correctly, and it runs on every path including no-LLM (so verbatim markers are always stripped and
  the span restored even with no rewrite).
- Within a position, order is **explicit (index), never incidental** (DRY, no hidden
  ordering in code paths).

*(Open: whether users can reorder within a position, or only the defaults are exposed.
Default to not-exposed until needed — YAGNI.)*

### 4.3 Modes & routing
A Mode is a **named bag of config** the generic pipeline executes. The pipeline never
branches on a mode's name or purpose (`principles.md` §2). Routing happens in two phases
because some triggers are known before speech and some only after:

**There is no separate "global hotkey."** A hotkey always belongs to a mode; the familiar
Fn/Globe key is simply the **default mode's** trigger key (`principles.md` §2 — the default is
an ordinary mode, not special-cased). What users informally call "the global hotkey" is that
default-mode key.

**Phase A — known before STT (full pipeline available):**
- **Trigger key(s):** press styles are **hold-or-tap** (push-to-talk while held *or* fires on
  a quick tap), **hold-only**, and **tap-to-toggle**. A key **selects its mode** as the initial
  mode and runs that mode's *entire* pipeline including pre-STT bias. When a *single* mode owns
  the key, pressing it invokes that mode even where context would not auto-select it — a
  deliberate press is never a no-op. When **several modes share the key**, context
  disambiguates: the bound mode whose app/URL constraints best fit the current context wins
  (most specific, then declaration order), with an unconstrained bound mode as the fallback —
  so one key can drive a Slack-only mode in Slack and a plain mode everywhere else. (The STT
  *engine* is global — modes do not pick it; see §4.1.) Any key
  is **capturable** — the **recommended default is Fn/Globe with hold-or-tap** (the most
  familiar gesture; Wispr and Apple both center on it), bound to the default mode, with
  **right-Option** as a conflict-free alternative (Apple Dictation also double-taps Fn).
  Holding **Hyper** (⌃⌥⇧⌘) can be a trigger. Conflicts with system/other-app shortcuts are
  handled **best-effort** (detect and warn at assignment).
- **Context constraints (bundle / URL):** we identify the frontmost app, and the URL when we
  can, **best-effort**, to **rank the eligible modes** in that context. Context *suggests* the
  starting mode; it does not restrict an explicit key press. The eligible set also bounds
  Phase-B voice routing.

**Mode resolution (one resolver, both phases).** When no key is pressed, Phase A picks the
initial mode; when a transcript suffix matches, Phase B picks the routed-to mode. Both use the
**same rule over the eligible (context-allowed) modes: specificity first, then declaration
order.** A mode constrained to the *current* context (app, or app+URL — URL is narrower than
app) outranks a less-constrained one; an **unconstrained** mode is the least specific. Equal
specificity breaks by the mode list's declaration order. Only **constrained** modes auto-start
in Phase A; if none match, resolution falls to the single **default mode**. Unconstrained
*non-default* modes never auto-start — they are reachable by **key or voice only** (so two
catch-alls never compete to start).

**Phase B — known only after STT (trigger-phrase routing):**
- **Trigger phrase(s) (regex):** a mode may have **multiple** phrase regexes (e.g. *"as pig
  latin"* or *"pig latinize"* both route to the same mode). Because they depend on STT output
  they **cannot run pre-STT**. If the transcript suffix matches an eligible mode's phrase,
  KeyScribe **adopts that mode's remaining post-STT pipeline** and strips the matched suffix
  (raw-suffix routing). When several eligible modes match the same suffix, the **specificity →
  declaration-order** rule above picks the winner (a Chrome-constrained mode beats an
  unconstrained one in Chrome; an Obsidian-only mode is simply not eligible there).
- **Routing adopts only the *post-STT* pipeline.** The base mode's pre-STT stages already ran
  and are not redone; the routed-to mode's pre-STT stage (dictionary **recognition bias**, the
  only pre-STT stage) **never applies on a voice route** — recognition bias is fixed at STT time
  from the Phase-A mode, before the suffix that triggers a Phase-B route is even transcribed. Whisper
  (conditioning prompt), Apple (contextual strings), and Parakeet (CTC-WS) all support recognition
  bias (§4.1). So a voice-routed mode forgoes only its *own* dictionary's recognition-bias
  contribution; its dictionary still feeds the post-STT LLM "valid term" hint. An edge case worth
  knowing, not a correctness concern.

Each mode also carries:
- **Dictionary & replacements** of its own, and may optionally **exclude the global**
  dictionary/replacements.
- **Privacy toggle** — when on, best-effort redaction (§4.2) runs for this mode (the mode's
  privacy indicator), and **context is disabled and prevented** for the mode (§4.4): the
  context checkboxes are forced off and locked, so no window/app/selection text can be sent to
  the cloud alongside the transcript. Redaction therefore only has to cover the transcript.
- **Live-edits opt-in** — whether the spoken command list (new line, paragraph, scratch that,
  begin/end verbatim) is active for this mode.
- **Context opt-in** — checkboxes for what to send to the LLM: **App**, **visible
  text**, and **preceding text** (bounded text before the caret, native-only/best-effort) (§4.4).
  (The URL is a routing key only, never sent — §4.3.)
- **Shared prompt fragments** — named, reusable snippets **appended** to the mode's prompt
  (e.g. a "my voice" fragment shared across email and Slack modes). Appended in order, kept
  simple.
- Optional **AI rewrite** (a **named LLM connection** + prompt + fragments + opted-in context).
- **Insertion method**; **exclude-from-history**.

**Default mode.** There is always a **default mode** (plain dictation) used when no key,
context, or phrase selects another. It **owns the recommended hotkey** (Fn/Globe) and is the
catch-all the resolver falls back to when no constrained mode matches the context. It is an
ordinary mode, not special-cased in code (`principles.md` §2) — "default" is just a designated
role: the unconstrained mode that auto-starts.

**Edit-in-place is a capability, not a magic mode.** We do not ship a special "edit
selection" mode — we provide the *ability* for any mode to be configured this way. The flow:
1. user **selects text** in the target app,
2. presses the **mode-specific key**,
3. **dictates transformation instructions**,
4. the mode combines its **prompt + the transcribed instructions + the selected text** and
   the LLM produces the result, which **overwrites the selection**.

This requires a reliable **"copy selected text" capability**. **Spike result:** synthesized
**⌘C → read pasteboard is the universal method** (worked in Electron/Chromium/native); AX
`kAXSelectedText` is a **native-only** enhancement (empty on Electron/Chromium), so ⌘C-copy is
the primary path and AX a bonus where present. It is acknowledged as the case that bends the
Mode model (input is selection+voice, output overwrites), but it stays a configured mode, not
an engine fork.

### 4.4 AI rewrite context
A mode **opts into** the context it sends to the LLM via checkboxes — **App**,
**visible text**, and **preceding text** (a bounded amount of text immediately before the caret,
native-only and best-effort) — plus the current selection when it is an edit-in-place mode. Nothing
is sent that the mode did not opt into. Optional, BYOK, and only over redacted payloads.

**The URL is never sent to the LLM.** It is a *local* routing key only (`url_pattern`, §4.3):
matched against a regex on-device to rank modes, never transmitted. As rewrite context it adds
little over the app identity plus the visible-window text (which already carries what page the
user is on) while disproportionately widening the cloud payload — URLs routinely embed session
tokens, record ids, and search queries the user never sees. So URL is scoped to routing; app
identity, visible text, and preceding text are the only situational context channels.

**App detection (spike result):** the frontmost **app/bundle id is always available**. (Browser
**URL detection** — AppleScript/Apple Events per browser, not AX — is described under routing,
§4.3/§4.5, since it feeds `url_pattern` only.)

**Privacy mode forces context off.** When a mode's privacy toggle is on (§4.3), the context
checkboxes are **disabled and locked off** — visible/app/selection text is never attached.
This is the deliberate resolution to the payload-leak problem: rather than run redaction over
large untrusted context blocks (and miss things, best-effort), privacy mode simply **prevents
context from leaving at all**, so the redacted transcript is the only user content in the cloud
payload. Context-aware rewrite and privacy are therefore mutually exclusive per mode by design.

- **v1: fixed structure.** Opted-in context chunks are appended as **fixed, clearly-delimited
  blocks** in a stable order, alongside the mode's prompt and shared fragments. Prompt +
  system-prompt structure is designed in `prompt_design.md`.
- **Later: prompt templating.** Letting users place chunks at *specific* points in the prompt
  via templates is powerful but a **confusing footgun** — deferred (YAGNI). v1 only appends.
- **LLM floor: Gemini 2.5 Flash.** The lowest-common-denominator target. Prompt structure is
  tuned to be reliable on a fast/cheap model — explicit, well-delimited, concise — not
  dependent on top-tier instruction-following.

### 4.5 Insertion
**Paste is the primary method.** Spike-confirmed: paste lands text across Electron/Chromium/
native and **undoes in a single ⌘Z**. **AX-insert and type proved unreliable** (no visible
insert in several apps; some apps also intercept the keystrokes) — they are built as opt-in
`mode.insertion` choices for the few targets that benefit, not the default. AX-insert sets the
focused element's selected text but **does not trust the API's `.success` return** — Chromium/
Electron return success and silently no-op it (live-confirmed: text vanished, not even on the
clipboard). It only takes the AX path when it can read the field value back and confirm it changed,
else **falls back to paste** — so `insert` uses AX on native fields and paste on web/Electron and
never loses text. Type posts Unicode key events with no success signal, so it is best-effort with
no fallback. The focus-race clipboard fallback (below) overrides whichever method the mode picks.
- **Permission reality (spike-confirmed):** **three** TCC categories — **Accessibility** (post
  ⌘V/⌘C and AX reads; `kTCCServicePostEvent` for posting, `kTCCServiceAccessibility` for AX,
  both shown under "Accessibility"), **Input Monitoring** (the global-hotkey event tap), and
  **Automation/Apple Events** (browser URL via AppleScript, per browser).
- **Principle:** minimize the permission surface. Prefer paste; do **not** require AX-insert if
  it is the *only* reason to ask for a permission. Request **Automation** only when a mode
  constrains by URL (`url_pattern` routing, §4.3). (TCC services and Electron behavior now validated by spike.)

**Target capture & focus race.** The target (frontmost app, focused element if AX exposes it,
and a selection snapshot) is captured **at trigger time**. Because batch + LLM rewrite takes
seconds, focus may move before insertion. We verify best-effort at insert: app/focus change is
reliably detectable; **field-level** change is detectable on native apps but often **only
app-level on Electron**. On mismatch or uncertainty, we **fall back to the clipboard** and a
HUD notice rather than risk inserting in the wrong place. (No competitor publicly commits to
solving this — it is a known hard problem; we commit to best-effort + a safe fallback.)
- **Paste last dictation** — a command to paste the most recent result on demand (the
  universal fallback).
- **Serialized dictations** — a new dictation is queued or rejected while one is still
  processing; no overlapping insertions (v1).

### 4.6 Settings (per scratch pad)
- **General:** load on login; **STT model eviction** (Fastest = keep loaded, no eviction;
  Balanced = evict after an idle timer; Frugal = evict after each dictation); during-dictation
  (mute system audio, keep display awake, sound on start/end); local history.
- **Speech models:** download/select/delete.
- **Dictionary & Replacements:** global lists.
- **AI Service (BYOK):** **named LLM connections** — each a `(name, provider, model, key-ref
  in Keychain, params)`. Modes reference a connection by name; multiple connections allowed
  (best-of-breed connection UX, cf. LibreChat — `principles.md` §5).
- **Modes:** full mode editor (§4.3); each mode persists as a **TOML** file. Schema and the
  referenced config files are specified in `config_schema.md`.

The settings information architecture, progressive-help contract, and control behavior are
normative in `ui_design.md` and `ui_components.md`.

### 4.7 Local history
Optional, **on-device only** (a **`history/` directory with one JSONL file per day**,
append-only), never synced. A **simple retention policy** bounds it (delete day-files older
than N days, or cap entries). Per-mode "exclude from history."

**Stored per entry:** raw transcription, the mode used, the **exact prompt sent to the LLM**,
and the **final text pasted/inserted**. **Audio is never stored.** The stored prompt carries
the **tokens** (⟦SN:…⟧), not their originals — the **redaction map is never stored** — but the
raw transcription and final insert do contain the real values, so for sensitive work the lever
is **disabling history** for that app/mode (per-mode "exclude from history").

**History is also a correction surface:** from a history entry the user can quickly define a
**replacement** or **dictionary** entry to fix what was misheard — the common "that came out
wrong, never again" loop.

**Minimal correction loop ships early (M3), before the full history surface (M7).** A **global
shortcut** opens a small "add correction" panel — **Heard → Replace** (a global replacement) or
**add as a dictionary term** via one toggle — with the **Heard** field **pre-filled from the
current selection** when text is selected in the target app. This is the fast "the 23rd word was
wrong" fix; the searchable history view that also offers it lands in M7.

### 4.8 Dictation feedback
- **Sound** on dictation start and end.
- **Floating HUD** — small, clear, and **movable** on screen. Shows a **live voice indicator**
  (input level), **whether the cloud is involved** (a BYOK LLM rewrite is part of this
  dictation), and a processing state while the LLM runs. Consistent with the visual language
  (`principles.md` §6).

HUD states, data-boundary wording, and fallback behavior are normative in `ui_design.md`.

### 4.9 First-run & onboarding
- **Progressive permissions** — request the minimum to start (dictation + paste); ask for
  context-reading only when a feature that needs it is enabled.
- **Seeded example modes** — first launch installs a few helpful example modes so the value
  is immediate and the user has working templates to learn from. Examples demonstrate generic
  capabilities, not hardcoded app identities: Plain Dictation, Polished Dictation, and Work on
  Selection.

---

## 5. Technology choices (proposed)

- **Language/UI:** Swift + SwiftUI (menu-bar app, settings window). Native for perf,
  accessibility APIs, and Apple SpeechAnalyzer access.
- **STT:** **FluidAudio** (Parakeet TDT v3 + pyannote diarization, CoreML/ANE) as primary;
  whisper.cpp / WhisperKit for Whisper; system `SpeechAnalyzer` for Apple.
- **Audio:** AVAudioEngine for capture; system-audio muting via Core Audio.
- **Global hotkeys / insertion:** CGEvent (`kTCCServicePostEvent`) for paste keystroke;
  Accessibility (`kTCCServiceAccessibility`) for context reading and optional AX insert.
- **LLM:** thin BYOK client over OpenAI/Anthropic/Gemini HTTP APIs; keys in Keychain;
  connection UX modeled on best-of-breed (LibreChat).
- **Storage (file-based, no DB):**
  - **Modes → TOML files** (one per mode) — human-readable, hand-editable, diff/version
    friendly, and naturally data-driven (`principles.md` §2).
  - **History → `history/` directory, one JSONL file per day** (append-only) — greppable,
    streamable, simple; retention drops old day-files.
  - **Global dictionary & replacements → TOML.**
  - **Shared prompt fragments → `fragments/` directory, markdown + YAML frontmatter** (prose
    body; structured config stays TOML).
  - **LLM connections → TOML** (key material in Keychain, referenced by id).
  - **STT weights → `models/` dir** under the support root (runtime-downloaded, never committed,
    backup-excluded; §4.1).
  - **Redaction/verbatim maps → in-memory only**, never persisted.
  - No SQLite for v1 (simple architecture, YAGNI). Revisit only if history search outgrows
    line-scanning JSONL.
- **Distribution & updates:** direct distribution, **notarized** (Developer ID) — **not** Mac
  App Store, whose App Sandbox restricts the AX APIs we depend on. **In-app updates** (e.g.
  Sparkle) with a **menu-bar indicator** when an update is available.
- **Open source & model weights:** KeyScribe is **open source**. STT/diarization **weights are
  downloaded at runtime, not bundled in the repo**, keeping the source tree license-clean. A
  **`THIRD-PARTY-NOTICES`** file credits the models — Whisper (MIT), Parakeet
  (CC-BY-4.0 / Apache-2.0 CoreML build), pyannote diarization (CC-BY-4.0, attribution
  required), FluidAudio SDK (Apache-2.0). **Project license: GPLv3** — open source; a notarized
  binary may still be sold (the VoiceInk model).
  - **License call (decided — minimum, no heavyweight legal spike):** keep **GPLv3**. It is
    compatible with our deps (Apache-2.0 and MIT code flow into a GPLv3 project; weights are
    runtime-downloaded *data*, not linked code, so the source tree stays clean), matches the
    open-source intent, and permits selling notarized binaries provided source is offered.
    **The entire legal obligation is four things:** (1) a GPLv3 `LICENSE`; (2) a
    `THIRD-PARTY-NOTICES` file with the Whisper/FluidAudio/Parakeet/pyannote attributions;
    (3) **CC-BY-4.0 attribution surfaced in-app** (a credits/notices screen) for Parakeet
    weights and pyannote — CC-BY requires visible attribution, a buried file is the risk;
    (4) weights downloaded at runtime, never committed. No CLA. Re-confirm these four licenses
    are unchanged at ship time — that is the whole check, not a per-dependency legal table.

### 5.1 Config schema versioning & migration
Every persisted config file (**modes, LLM connections, dictionary/replacements, general
settings**) carries a **`schema_version`** from day one.
- On load, files below the current version are upgraded through an **ordered, forward-only
  migration chain** (v1 → v2 → …) and rewritten. Each file type owns its own version and
  migration steps, run by **one shared migration runner** (DRY).
- A file from a **newer** version than the app understands is **not silently downgraded** —
  the app surfaces it and leaves it untouched.
- A **pre-migration backup** is written so a failed or unwanted migration is recoverable.
- User-editable files are **validated** on load; invalid files surface a clear error rather
  than being silently dropped.

*(All subject to validation in M0 — see roadmap.)*

---

## 6. Differentiation summary (vs `competitors.md`)

| Capability | KeyScribe | Superwhisper | Wispr Flow | VoiceInk | Apple |
|---|---|---|---|---|---|
| STT always local (no cloud STT) | ✅ | ✅ (opt) | ❌ cloud | ✅ | ✅ |
| Pluggable engines | ✅ 3–4 | ✅ 2 | ❌ | ✅ 1 | n/a |
| Per-context modes (data-driven) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Staged pipeline (pre/post STT+LLM) | ✅ **unique** | partial | ❌ | ❌ | ❌ |
| Redaction + restoration (cloud-safe) | ✅ **unique** | ❌ | ❌ | ❌ | ❌ |
| Dynamic, state-driven system prompt | ✅ **unique** | ❌ | ❌ | ❌ | ❌ |
| Voice-edit selected text | ✅ | partial | ✅ | ❌ | ❌ |
| BYOK rewrite | ✅ | ✅ | ❌ | ✅ (opt) | ❌ |
| Simple default UX | ✅ goal | ⚠️ complex | ✅ | ⚠️ | ✅ |

---

## 7. Open questions / risks

- **FluidAudio batch latency.** Confirm in M0 that end-to-end latency for short utterances
  feels instant. Streaming is not required.
- **Insertion + permissions.** Paste is primary, but confirm exact TCC services
  (`kTCCServicePostEvent` vs `kTCCServiceAccessibility`), App Sandbox / App Store
  implications, and Electron field behavior. Decide whether AX-insert earns its permission.
- **Two-phase routing UX.** Trigger-phrase routing only affects the post-STT pipeline. The
  single-global-engine rule (§4.1) removes the worst confusion (a phrase mode never changes
  the engine because nothing does per-mode), but the post-STT-only limitation still needs a
  clear UI story.
- **Redaction correctness across the LLM boundary.** Nonce-token fencing + dynamic system
  prompt must be robust to models that paraphrase or drop tokens — needs a test harness.
- **Voice-edit-selection ergonomics.** It bends the Mode model (selection-as-input,
  overwrite-as-output); make sure it stays a clean special case, not a fork in the engine.
- **Pricing/business model** — deferred (out of scope per current decision); revisit before
  launch.
