# KeyScribe — Build Status & Remaining Work

> Companion to `design.md`. The full feature set ships: the whole pipeline works end-to-end —
> local dictation → modes (Phase-A app/URL/window-title routing + Phase-B trigger-phrase routing + per-mode
> trigger keys) → dictionary / replacements / live edits / numbers / fuzzy → optional **BYOK
> rewrite** with explicit data-boundary UI → **verbatim spans** and best-effort sensitive-text
> tokenization for recognizable patterns → atomic insert. Plus edit-in-place, up to 8 STT
> models with
> recognition bias on every offered model except Moonshine and dictionary recovery for Moonshine, the
> Settings UI
> (General · Speech Models · Vocabulary · AI Services · Modes · Permissions · Advanced), local
> history with the correction surface, and the standalone correction panel.
>
> What follows is the work that is **not** done.

---

## Remaining work

### Distribution & updates
- **Sparkle decision and implementation.** The menu-bar **update badge** (amber dot, top-right —
  `ui_design.md` §6), the matching update menu item, and the `AppUpdater` injection seam
  (`Sources/KeyScribeKit/AppUpdater.swift`) are built and wired. Sparkle is now on the table for the
  public app, so the stale "Homebrew only, no updater" plan is retired. Before 1.0, decide and land
  the actual update contract: appcast hosting, EdDSA signing keys, release-note source, update cadence,
  failure UX, and release/preflight coverage.
- **Release packaging floor alignment — resolved.** The app bundle and `Package.swift` declare macOS
  15.0, and Apple Speech is availability-gated to macOS 26+. The Homebrew cask now relaxes to the app
  floor (`depends_on macos: ">= :sequoia"` in `scripts/update-cask.sh`) so Sequoia users can install;
  Apple Speech simply stays hidden on 15 via its `@available` gate.

### Polish
- **Mode editor simplification — mostly resolved.** The editor now uses a progressive surface:
  common settings are visible, routing and recognition/replacements carry the remaining disclosures,
  cloud-boundary controls are grouped under "Data sent with AI", and riskier escape hatches stay
  TOML-only with read-only notes. Remaining 1.0 work is visual QA across every seeded mode, especially
  long names, disabled dependency reasons, and small-window wrapping.
- **Accessibility / error-state / onboarding polish — partially resolved.** Done: Settings has
  accessibility labels for problem indicators/data-boundary badges, the HUD respects Reduce Motion
  and offers concrete repair actions for microphone/accessibility failures, first run has
  **Skip for now** paths, and permission setup explains the Accessibility relaunch requirement.
  Remaining 1.0 work is a real VoiceOver/keyboard pass through first run, Settings, HUD actions,
  and the correction surfaces.
- **Verbatim pause-artifact punctuation — mostly done.** Pausing around the markers makes the STT
  terminate each clause with a period (`…sentence. Begin verbatim. …contents. End verbatim. This…`).
  Handled in `VerbatimTokenizer` + `spliceAbsorbing(foldBracketedTerminators:collapseTrailingTerminator:)`:
  begin-marker-glued terminators are stripped, verbatim spans no longer fold into the preceding clause,
  and a redundant post-`end verbatim` terminator collapses into the content's own (never stripping the
  content's, so an intended `Hello!` survives). Validated on real audio — `corpus/commands`
  `vb_pause_sentence`, clean on Whisper. Two things remain:
  - **Deferred (ambiguous):** a pause terminator the STT glues to the *content* before `end verbatim`
    with no post-marker terminator to collapse against is indistinguishable from an intended one
    (`contentTerminatorIsPreserved`), so it is left as-is.
  - **Trigger-recognition gap:** when an engine mishears the `end verbatim` trigger (Parakeet
    `"En verbatim"`, Apple `"and verbatim"`), the span runs unterminated and swallows the tail — a
    fuzzy-end-marker matching problem, not punctuation. Any future work here needs `--commands-check`
    with a real-voice recording (`say` cannot reproduce the mid-utterance pause periods).

### Settings-editor follow-ups
- **Immediate-apply settings model — resolved.** The old "add explicit Save" note was stale. The
  current UI follows the macOS Settings model better: ordinary text fields commit on Return, focus
  loss, or teardown; Escape reverts to the last committed value; multiline prompt editors commit on
  focus loss except where a dismissing popover needs a dependable live/flush save; credentials keep
  explicit actions such as **Save key**, **Fetch Models**, and **Test Connection**. Keep this model
  unless user testing shows data loss or surprising writes.

### AI rewrite
- **AI Services polish:** the pane now uses progressive sections for service, endpoint,
  authentication, model discovery, and connection test. OpenAI-compatible endpoints support no auth,
  a Keychain-backed API key, or a command-generated bearer token. Remaining polish is narrow: long
  discovered model names can make the native picker wide, and the unsaved-key state needs continued
  visual QA.
- **Reposition privacy-mode language.** Do not market redaction as reliable protection. It is a
  best-effort pattern matcher over the STT transcript, so it can miss content the recognizer verbalizes
  or normalizes (for example, an email spoken back as words). The stronger positioning is:
  speech recognition is local, rewrite is explicitly BYOK and mode-scoped, context sharing is visible
  and can be locked off, history/config are local files, and redaction is only an extra safety margin
  for recognizable patterns. For content that must never leave the Mac, use a no-rewrite mode.
- **Inline prompt slots (power-user prompt layout).** Today `PromptAssembler` builds a fixed
  `<context>` block (app / field / selection / preceding) and a mode's prompt is the system
  message. Add optional `{{ … }}` slots a user can place *inside* the prompt body —
  `{{ dictation }}`, `{{ selected_text }}`, `{{ text_before_cursor }}` — so the prompt itself
  becomes the user-message layout (with a fixed system guard,
  keeping untrusted context out of the trusted channel). Composable **prompt fragments** already
  exist (`Mode.AIRewrite.fragments` → `RewriteRequestBuilder`/`ResolvedConfig.fragmentBodies`), so
  slots layer on top of them. Also add the **whitespace-preservation rule** (emit only when the
  transcript contains newlines/tabs, telling the model to keep literal line breaks/blank lines as
  intentional voice formatting). All pure/testable in `PromptAssembler`; the injection-defense
  `neutralize()` and language rule already exist. No extra LLM calls; gives power users precise
  control over prompt layout.

---

## Cross-cutting invariants (hold for every change)
- **Privacy invariant:** audio and local dictation stay on device; nothing leaves the device except
  explicit model downloads and mode-scoped BYOK rewrite calls; **no telemetry/analytics**.
- **Config versioning:** every persisted config file carries `schema_version`; a forward-only
  migration runner upgrades older files on load (backup first), per `design.md` §5.1.
- **Progressive disclosure:** a new power feature must not complicate the default path.
- **Insertion regression suite:** re-run the field-compatibility matrix as stages are added.

---

## Parked (post-v1)
- **Diarization-as-a-feature** + file/batch transcription + rich export (MacWhisper's space). The
  diarization *capability* comes free with FluidAudio (Parakeet v3); this is about productizing it.
- **OCR context fallback** for true canvas / sparse-AX apps (e.g. Figma, Gmail SPA). Hard-deferred:
  narrow value × niche app set × a trust-costly Screen Recording grant.
- **Cross-platform** (Windows).
- **Pricing / business-model** decision (open-source vs closed, freemium surface).
- **Per-mode few-shot examples** on a mode's AI rewrite (à la Superwhisper's "Examples of correct
  behavior"). Measured benefit on the ship floor is modest — consistency/output-only polish for
  formatting-heavy modes (Markdown), not correctness rescue. Consider, do not assume.
- **Fuzzy-corrector common-word guard.** `FuzzyCorrector`'s only harmful failure mode is overwriting a
  *correct* common word that shares a dictionary term's consonant skeleton within 2 edits
  (`cloud`→`Claude`, `cube`→`Kube`); the phonetic gate already blocks the rest (`lava`→`Java` survives).
  Measured risk is low for normal dictionaries — ~0.02% WER harm on non-term speech with a ~50-term dict,
  net WER *improvement* on real STT — and only grows with dictionary size (~1.5% harm at ~1k terms,
  upper-bound). A guard that skips the *fuzzy* snap when the source token is itself a common English word
  (the exact/spacing-merge path stays) would drop harm to ~zero while keeping the wins (`sellery`→`Celery`,
  `charge bee`→`ChargeBee` are non-words, untouched). **Deferred because the obvious implementation needs a
  bundled frequency-ranked word list (~top 10–50k), which we do not want to ship unless forced.** Revisit
  if telemetry-free signals (user reports, larger default dictionaries) show real over-correction, or if a
  no-bundle source for "is this a common word" appears (e.g. a system lexicon API). Harness to re-measure
  exists in session notes (drive the real corrector over the corpus with controlled dictionaries).
- **Whisper on ANE for power efficiency.** The WhisperKit engine deliberately pins `.cpuAndGPU` (Metal)
  for mel/encoder/decoder (`WhisperEngine.swift`), not the conventional `.cpuAndNeuralEngine`. ANE is
  meaningfully lower-power (and lower-latency) for interactive single-shot inference — the right default
  for an intermittent dictation model — so **giving it up is a real, ongoing battery cost on the Whisper
  engines**, the one thing this choice trades away. It was forced, not preferred: ANE's ~140 s first-load
  device-compile failed to cache on our path and got paid on *every* load, whereas Metal compiles once
  (~24 s first, ~2 s cached, persisted across launches). For a model loaded/evicted intermittently, load
  time dominated, so Metal won on total responsiveness. Revisit ANE if (a) the ANE compile-cache issue is
  fixed upstream (Argmax/Core ML) so the first-load cost amortizes, or (b) `prewarm` can hide the compile
  so load time stops dominating — then re-measure power draw (ANE vs Metal) and RTF before switching.
  Parakeet/FluidAudio is unaffected (separate runtime); this is Whisper-engines-only.
