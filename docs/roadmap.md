# KeyScribe — Roadmap

> Companion to `design.md`. Decision: **the full scratch pad ships as v1.** So this roadmap
> is a *build-order* for reaching that complete feature set — not a feature-deferral plan.
> Sequencing is driven by dependency and risk: de-risk the engine and the insertion loop
> first, layer the pipeline and modes on a working core, polish last.

Legend: **M** = milestone. Each milestone is independently demoable.

---

## M0 — De-risking ✅ complete
The scariest unknowns are retired via throwaway spikes in `spikes/` (see its README logbook).
Proven results, folded into `design.md`:
- **STT loop (FluidAudio/Parakeet):** reload-from-cache **0.13s** · transcribe **74–90ms** ·
  resident **~27–38MB** · perfect on synth speech · Apache-2.0/CC-BY licenses cleared.
- **Insertion:** paste lands across Electron/Chromium/native + **single ⌘Z**; AX-insert/type
  unreliable → paste-primary.
- **Permissions:** **3 TCC categories** — Accessibility, Input Monitoring, Automation (browser URL).
- **Hotkey:** Fn/Globe and right-Option both capturable & distinguishable.
- **Context:** bundle id always; **⌘C selection universal**; **URL via AppleScript** (not AX).
- **Token-fencing:** survives LLM rewrite (local proxy); sentinel choice de-risked.
- **Runtimes/libraries decided** (`design.md` §5).

Carried forward — **not gates**, handled in the milestone where they belong:
- Real-voice / noisy / accented STT quality + latency/memory **budgets** → measured in **M1** (real mic).
- Hold / tap / double-tap **press-style** timing → built in **M1**.
- **Dictionary recognition bias** per engine → all three via `transcribe(wavURL:biasTerms:)`: Whisper
  (prompt), Apple (contextual strings / DictationTranscriber), Parakeet (FluidAudio CTC-WS). Verified
  live in M2.
- Final **Gemini 2.5 Flash** token pass + adversarial cases → **M6**.

## M1 — Core dictation loop (one engine, end-to-end)
**Goal:** the simple default experience works for a real user.
- [x] `SpeechEngine` interface (resolved through one provider) + **Parakeet via FluidAudio**
      implementation.
- [x] Audio capture (AVAudioEngine), endpointing; **batch transcript on key-release**.
- [x] Insertion stage with all 3 methods (paste / AX-insert / type; AX-insert degrades to paste on
      failure); clipboard save/restore for paste; **atomic insert so one ⌘Z undoes the whole
      dictation**.
- [x] **Capturable trigger keys**; **default Fn/Globe (hold-or-tap)**, right-Option as the
      conflict-free alternative, Hyper chord supported; best-effort conflict warning.
- [x] **Target capture at trigger** (app/focus/selection snapshot) + best-effort verify at
      insert → **clipboard fallback** on mismatch; **Paste last dictation** command;
      **serialized dictations**.
- [x] Minimal first-run: download model (progress) → grant Mic/Input-Monitoring/Accessibility
      just-in-time → pick hotkey → talk. Full sequence is normative in `ui_design.md` §2.
- [x] **Floating HUD** (small, clear, movable; live voice indicator) + **start/end sounds**;
      keep-display-awake; mute-system-audio. (Cloud-involved indicator lands with M5.)
**Exit:** ship-quality basic dictation, on-device, no settings required.

## M2 — Engine choice + model management (one active engine)
**Goal:** deliver the "privacy + choice" engine story — choose one engine globally.
- [x] **Apple SpeechAnalyzer** behind the interface (native macOS 26, batch file flow); the
      provider exposes exactly **one active engine** at a time and switching evicts the prior.
      **Whisper** is SDK-wired on our WhisperKit-1.0.0 fork (decision note below). **Seven models have
      run live (2026-06-21):** two Parakeet tiers, Whisper, Apple, **Qwen3-ASR 0.6B + 1.7B** (MLX, via
      `rsperko/speech-swift` fork), **Moonshine Base EN** (ONNX). All wired through one `EngineRegistry`
      descriptor list. Six bias-capable; Moonshine is bias-exempt. A dev `--benchmark` harness measures
      WER/recall/RTF per engine — Qwen3-1.7B leads (0.8% biased WER); see session-status.
- [x] Speech-models settings: engine cards with select / download(progress) / delete +
      confirmation, governed by the tested selection/deletion rules.
- [x] Global engine selection from the **curated model list** (Parakeet TDT v3 + Parakeet TDT-CTC
      110M + Whisper + Apple + Qwen3-ASR 0.6B + Qwen3-ASR 1.7B + Moonshine Base EN); language follows
      the active engine. (Per-mode engine and custom STTs stay seam-only — `principles.md` YAGNI.)
- [x] **Engine recognition bias** — all three engines accept dictionary terms via
      `transcribe(wavURL:biasTerms:)`, each via its model's own mechanism, **all verified live
      2026-06-21**: Whisper (`promptTokens`), Apple (`contextualStrings`, requires
      `DictationTranscriber` — `SpeechTranscriber` ignores it), Parakeet (FluidAudio **CTC-WS**
      constrained-CTC keyword spotting on both tiers). Two engines run on small forks (see notes):
      WhisperKit for the #372 empty-output fix, FluidAudio for the `enableSpotterRescue` toggle (off on
      the weaker ctc110m, where the acoustic-only rescue false-fired). (An interim `EngineCapabilities`
      flag seam was added then removed — `design.md` §4.1.)
- [x] **Parakeet recognition bias — resolved via FluidAudio CTC-WS**, not the once-planned sherpa-onnx
      migration. FluidAudio ports NeMo's CTC-WS keyword spotter; `ParakeetEngine` pairs each TDT model
      with its same-tier CTC model and confidence-gates replacements (per-model tuning in
      `ParakeetModelProfile`). The sherpa-onnx path (spike in `spikes/`, CPU-only) is no longer needed
      — kept only as reference.
- [x] **STT model eviction** policy: Fastest / Balanced (idle timer) / Frugal — pure tested
      `EvictionPolicy`, wired into the dictation loop + a General ▸ Advanced control.
**Exit:** user picks one of 3 engines as the global active engine; models managed in-app.

> **Whisper SDK decision (RESOLVED + wired + run live).** Now pinned to our fork
> **`rsperko/argmax-oss-swift` @ `7cc6ea2`** (upstream **v1.0.0**); the original `0.9.4` pin was
> dropped (dead pre-monorepo branch, no fixes). The old "1.0.0 drags in Vapor + swift-openapi" worry
> was wrong — in 1.0.0 those are gated behind `BUILD_ALL`, so depending on just the `WhisperKit`
> product resolves clean (no Vapor). The fork adds a one-line `!isPrefill` fix for the
> empty-output-with-`promptTokens` bug (#372) that breaks Whisper bias in every stock release; filing
> it upstream + dropping the fork pin is a tracked TODO. `WhisperEngine` downloads the turbo variant
> and transcribes via `pipe.transcribe(audioPath:)` — see session-status.
>
> **Runtime status (verified interactively, 2026-06-21):** all four models — both Parakeet tiers,
> Whisper, and Apple — **transcribe + bias live**, plus frugal eviction. The Speech Models
> **download / select / delete UI flow is now verified live** too (2026-06-21), including launch-time
> marker↔disk reconcile (`ModelMaintenance`), post-install self-test (`ModelSelfTest`), and
> download-progress UI (`ModelLoadProgress`). See `docs/session-status.md`.
>
> **FluidAudio fork (Parakeet bias).** Pinned to `rsperko/FluidAudio` @ `b703677` (upstream 0.15.4):
> adds an `enableSpotterRescue` toggle to `ctcTokenRescore`. Parakeet bias is FluidAudio's NeMo CTC-WS
> (constrained-CTC keyword spotting), not the removed blind post-STT rescorer. Upstream PR is a tracked
> TODO in session-status.

## M3 — Dictionary, Replacements & Live edits (post-STT pipeline)
**Goal:** stand up the pipeline framework with its first stages.
- [x] Pipeline engine: **command-pattern `PipelineStage`** with explicit `StagePosition` +
      order index; canonical ordering per `design.md` §4.2.1 (live edits before replacements;
      replacements before tokenization). Wired into the live dictation flow before insertion.
- [x] **Replacements**: heard→replace, literal (case-insensitive) + regex with capture-group
      substitution; invalid regex skipped. Applied globally now; mode-local merge helper built.
- [x] **Live edits**: documented list — new line, new paragraph, scratch that (sentence/newline
      aware). Applied globally now; per-mode opt-in lands with M4. (Verbatim tokenization is M6.)
- [x] **Dictionary** + Replacements **config models** (TOML, `schema_version`, global+local
      merge) — tested. Dictionary's recognition effect uses per-engine bias (Whisper prompt, Apple
      contextual strings, Parakeet CTC-WS) plus the LLM "valid term" hint (M5).
- [x] **Global dictionary/replacement settings UI** — built: the **Vocabulary** pane
      (`VocabularySettingsView`) edits the global Dictionary and Replacements (shared `DictionaryRows`/
      `ReplacementRows`, reused by each mode's own vocabulary section). See "Settings UI" in
      session-status.
- [~] **Minimal correction loop** — the History detail's **Add to Dictionary** / **Create
      Replacement** (M7) is the correction surface; the standalone global "add correction" panel
      (global shortcut, Heard pre-filled from selection) is still deferred (`design.md` §4.7).
**Exit:** spoken structural commands work end-to-end (done); global vocab editing ships in the
Vocabulary pane (done); the standalone correction-panel shortcut remains.

## M4 — Modes
**Goal:** per-context configuration with auto-switching.
- [x] Mode model **persisted as TOML files** with `schema_version` (schema in
      `config_schema.md`); full field set, defaults, round-trip — tested.
- [x] **Migration runner** (shared, forward-only, backup-first) over `schema_version` — tested,
      reusable across every config type (`design.md` §5.1).
- [x] **Default mode** (plain-dictation) as the resolver fallback — an ordinary seeded mode.
- [x] **Seed the 6 starter modes** on first launch (plain / polished / message / email / prompt /
      work-on-selection). Rewrite-mode prompts tuned against the Gemini 2.5 Flash floor
      (`config_schema.md` seeded set, `prompt_design.md`).
- [x] **Phase A routing:** bundle context → eligible-mode set + chosen mode (app-specific
      preferred, else default) — tested and wired (mode name shows in the HUD).
- [x] **Per-mode physical trigger keys** — multi-binding `HotkeyMonitor` (global default + each
      mode's `trigger_keys`), exact chord matching (option+l vs hyper+l, tested). **Verified live**
      (right-Option → Work on Selection). Bindings rebuild on config change.
- [x] **App context + URL constraints** — app name+bundle is the LLM context channel (wired).
      Browser **URL** is a routing key only (`url_pattern`): `ContextProbe.browserURL` via
      AppleScript is wired and gated behind `requiresURLContext`. **Verified live** (2026-06-21): a
      `github\.com` mode resolved only on github.com and the default elsewhere, over the Automation
      grant. The URL is **deliberately never sent to the LLM** (design.md §4.4).
- [x] **Phase B routing:** trigger-phrase suffix regexes, constrained to eligible modes, re-route
      the post-STT pipeline and strip the matched suffix — tested and wired.
- [x] Per-mode replacements merged with global (or excluding it) + per-mode live-edits opt-in —
      wired into the live pipeline. Per-mode **dictionary** is modeled (effect needs M5 LLM hint).
- [x] **Context opt-in** + **shared prompt fragments** — parsed into the model (inert until M5
      rewrite); `effectiveContext` enforces privacy-forces-context-off.
- [x] Per-mode insertion method — `mode.insertion` (paste / insert / type) dispatches at insert
      time via the pure `insertionAction`; the focus-race clipboard fallback overrides the preferred
      method. Set per mode in the **Modes** editor's *Result handling* section.
- [x] exclude-from-history — applied: the history write is guarded on `!activeMode.excludeFromHistory`
      (`DictationController.swift`); the *Result handling* toggle sets it per mode.
- [x] **Mode-editor UI** — built: the **Modes** pane (`ModesSettingsView`) is a master-detail editor
      (create / edit / enable / delete) with sections for Basics, When this mode is used (trigger key +
      press style + Advanced routing for app/URL constraints and spoken phrases), What it does,
      Dictionary, Replacements, Improve with AI, and Result handling. See "Settings UI" in session-status.
**Exit:** different apps **and per-mode keys** activate different pipeline configs automatically
(done, verified live), a spoken suffix phrase re-routes the post-STT pipeline (done), and the
mode-editor UI ships (done).

## M5 — AI rewrite (BYOK LLM)
**Goal:** optional LLM rewrite, fully user-keyed.
- [ ] **Best-of-breed research first** (`principles.md` §5): study the cleanest
      LLM-connection UX (e.g. LibreChat) before designing the BYOK settings — pending.
- [x] **Named LLM connections** model (id, name, provider, model, `key_ref`, params) — TOML +
      tested; modes reference by id. **Keychain storage** (`KeychainStore`) done; the settings UI ships
      in the **AI Services** pane (see below).
- [x] Implement the **prompt / system-prompt structure** per `prompt_design.md` — output-only
      rules, XML-delimited instruction/context/content, conditional token + validTerms injection,
      empty-block omission — tested (`PromptAssembler`). Dynamic-from-pipeline-state assembly.
- [x] **Post-LLM validation gate** (`design.md` §4.2): token-integrity (exactly-once / no stray /
      deletion-aware) + non-empty; retry-stricter-once → local-fallback decision — tested.
- [x] **Output sizing** (`prompt_design.md`): `max_tokens` scales with selection length so an
      edit-in-place rewrite has room to return at least its input — `ContextBudget.maxTokens`, tested.
- [x] **Visible-text context + prompt-budget policy** (`prompt_design.md`, `design.md` §4.4): send
      surrounding on-screen text to the LLM as context, with priority budgeting — instructions/content
      never truncated, visible-text capped, refuse-over-budget. **Built + live-verified (2026-06-21):**
      `AXVisibleText` reads the Accessibility tree (no OCR — a spike proved the tree is readable *cold*
      across native/WebKit/Chrome/Electron on macOS 26), scoped to the largest content region
      (sidebar/nav excluded), off-main with a timeout + deadline + node caps. `ContextBudget.fit`
      reintroduced **test-first**. The system **context fence** that keeps captured text out of the
      output was **tuned against the model** (0/20 leak vs 6/10 for naive framing — see session-status).
      App context is wired; the URL is a routing key only (never sent to the LLM — design.md §4.4),
      wired and verified live (see M4). **AX-coverage probe over 12 real apps (2026-06-21)** confirmed
      the tree covers the common case; a couple of lazy-AX **Electron** apps (VS Code, Claude desktop)
      returned empty cold, so `capture` now does a zero-regression **`AXManualAccessibility` wake-on-empty
      retry** (not OCR — rides the existing grant; pending one live confirm). OCR fallback for true
      canvas/sparse-AX apps (e.g. Figma, Gmail SPA) stays **vetted hard-defer** (narrow-value signal ×
      niche app set × trust-costly Screen Recording grant; see `session-status.md`).
- [x] **RewriteService** orchestration + `LLMClient` seam: assemble → call → gate → retry →
      local-fallback, incl. graceful offline/no-key (client error → local fallback) — tested with a fake.
- [x] **Real network client** (`HTTPLLMClient`: OpenAI / openai_compatible / Anthropic / Gemini)
      + **Keychain** key fetch — wired into `DictationController` and **verified live against local
      oMLX** (a "polish that" mode rewrote text end-to-end with the key from Keychain).
- [x] **Voice-edit selected text** (edit-in-place): selection captured via ⌘C, transformed per the
      spoken instruction, replaces the selection — **verified live**; **non-destructive on every
      failure path** (no selection / no connection / rewrite failed → selection left untouched).
- [x] **Token-sentinel survival probe** + final sentinel pick — **done (2026-06-21)**. Probed the
      real production path against the Gemini 2.5 Flash floor: `⟦SN:…⟧` survived **24/24** across the
      hard rewrite shapes (translate/summarize/multi-token/adjacent/boundaries/edit-in-place), and a
      sentinel bake-off tied 24/24, so `⟦SN:…⟧` is kept (lowest stray/collision risk in prose).
      Harness: opt-in `SentinelSurvivalProbeTests`. See `prompt_design.md` open questions.
- [x] **BYOK settings UI** (connections management) — built: the **AI Services** pane
      (`AIServiceSettingsView`) is a master-detail editor — name, provider (OpenAI / Anthropic / Gemini /
      OpenAI-compatible), model, a `SecureField` API key saved to **Keychain** under `key_ref`, and an
      Advanced disclosure for the OpenAI-compatible Base URL. A mode's *Improve with AI* picker
      references a connection by id (and "Don't use AI (on this Mac)" clears the rewrite). The
      **best-of-breed connection-UX research** (`principles.md` §5) is still open.
**Exit (achieved):** a mode rewrites speech with the user's key (verified via oMLX); selecting text
+ speaking rewrites it in place (verified). Sentinel probe done (`⟦SN:…⟧` kept, 24/24 on Flash).
BYOK connections are managed in the AI Services pane (done); connection-UX research remains.

## M6 — Verbatim & Privacy/Redaction (pipeline's unique stages)
**Goal:** ship the differentiating, privacy-forward stages.
> **Sequencing call:** the wedge stays a **whole milestone here**, not fragmented into an
> earlier partial slice — the stateful tokenization (nonce map + LIFO restore) is one coherent
> body of work and splitting it would violate DRY/simple-architecture. It is de-risked instead
> by the **M5 sentinel-survival probe** and the **M5 validation gate**, and M6 is the headline
> wedge demo: "speak sensitive content → cloud polish on → provider never sees the span →
> restored locally."
- [x] **Stateful nonce tokenization** (`Tokenizer`): type+index tokens (`⟦SN:REDACT:1⟧`), same
      value→same token within a dictation, **in-memory-only** map (never logged), strict **LIFO**
      restore (nested case tested). Tested.
- [x] **Verbatim** (`VerbatimTokenizer`): "begin verbatim".."end verbatim" spans → single token,
      triggers stripped, case-insensitive, multiple + unterminated handled. Reinforced by the
      system-prompt token directive (`PromptAssembler`). Gated by live-edits opt-in at the call site. Tested.
- [x] **Redaction** (`RedactionTokenizer`): best-effort patterns (email, card, SSN, phone,
      OpenAI/AWS/GitHub keys), non-overlapping, tokenized before the LLM. Gated by the privacy
      toggle at the call site (which also forces context off, §4.4). Presented as best-effort. Tested.
- [x] **Robustness harness:** tokenize → assemble → model (preserve / drop) → `ValidationGate` →
      restore, on both success and fallback paths — proves protected spans never reach the model and
      restore is correct (incl. the local-fallback path restoring the tokenized local text).
- [x] **Wired into the dictation flow** — verbatim→redaction tokenize before the LLM call, restore
      after (both rewritten and local-fallback paths); **HUD shows "Best-effort redaction"** during.
      **Verified live:** dictated an email in a privacy mode, a proof log confirmed the outbound
      payload carried `⟦SN:REDACT:1⟧` (never the email), and the inserted result restored the email.
**Exit (achieved, verified live):** sensitive content is tokenized out before any cloud rewrite and
restored after; verbatim spans never mutate — proven in logic + the round-trip harness **and on the wire**.

## M7 — Local history & polish
**Goal:** finish the scratch pad and make it feel complete.
- [x] Local, on-device, searchable history (**`history/` dir, one JSONL file per day**,
      append-only) with a **simple retention policy** (drop day-files older than `retention_days`,
      applied at launch); per-mode `exclude_from_history` honored; `[history] enabled` toggle.
      **Stores** raw transcription, mode, exact LLM prompt (tokens, not originals), final inserted
      text, outcome + data-boundary metadata; **never audio**; **redaction map never stored**
      (`design.md` §4.7). Pure store/codec/retention/search **tested**; `HistoryStore` +
      `DictationController` recording wired. History **window UI built** (grouped/searchable list,
      Heard→Result detail, processing details, storage-truth footer) — **needs interactive verification**.
- [x] **History as correction surface:** **Add to Dictionary** / **Create Replacement** from a
      history entry (dedup-aware `adding(word:)` / `addingLiteral(heard:replace:)` + store `write`,
      tested). Detail-view buttons — **needs interactive verification**.
- [~] **Load-on-login** done (M1). General settings pass — partial.
- [ ] Progressive-disclosure UX pass: simple defaults forward, advanced tucked away.
- [ ] Accessibility, error states, onboarding polish.
- [ ] **Distribution:** direct, **notarized** (Developer ID); **in-app updates** (Sparkle)
      with the **update badge** (blue dot, top-right of the menu-bar icon — `ui_design.md` §6).
- [ ] **Error badge** (red dot, top-left of the menu-bar icon) for a configuration/model problem,
      with Settings surfacing visual hints to the exact cause (`ui_design.md` §6).
- [x] **Open-source release hygiene:** `THIRD-PARTY-NOTICES.md` (all engines + model weights),
      **GPLv3 `LICENSE`** at the repo root, weights downloaded at runtime (not committed), and the
      **in-app credits/notices screen** expanded to all 7 engines incl. CC-BY-4.0 attribution
      (Parakeet weights, pyannote) — CC-BY needs visible attribution (`design.md` §5).
**Exit:** full scratch pad implemented; v1 release candidate.

---

## Cross-cutting (every milestone)
- **Privacy invariant:** nothing leaves the device except explicit BYOK rewrite calls; **no
  telemetry/analytics**.
- **Config versioning:** every persisted config file carries `schema_version` from the first
  release; a forward-only migration runner upgrades older files on load (backup first), per
  `design.md` §5.1.
- **Progressive disclosure:** each new power feature must not complicate the default path.
- **Insertion regression suite:** re-run the field-compatibility matrix as stages are added.

## Parked (post-v1, from competitor gaps)
- Diarization-as-a-feature + file/batch transcription + rich export (MacWhisper's space).
  Note: diarization *capability* comes free with FluidAudio; this is about productizing it.
- 4th STT engine (Qwen3).
- Cross-platform (Windows).
- Pricing/business-model decision (open-source vs closed, freemium surface).
