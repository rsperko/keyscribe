# KeyScribe — Current Status & Roadmap

> Companion to `design.md`. The core feature set is built: the whole pipeline works end-to-end —
> local dictation → modes (Phase-A app/URL/window-title routing + Phase-B trigger-phrase routing + per-mode
> trigger keys) → dictionary / replacements / live edits / numbers / fuzzy → optional **BYOK
> rewrite** with explicit data-boundary UI → **verbatim spans** and best-effort sensitive-text
> tokenization for recognizable patterns → atomic insert. Plus edit-in-place, up to 8 STT
> models, recognition bias on every offered model except Moonshine, dictionary recovery for
> Moonshine, the Settings UI (General · Speech Models · Vocabulary · AI Services · Modes ·
> Permissions · Advanced), local history with the correction surface, and the standalone correction
> panel.
>
> What follows is the work that remains open.

---

## Remaining work

### Distribution & updates
- **Sparkle decision and implementation.** The menu-bar **update badge** (amber dot, top-right —
  `ui_design.md` §6), the matching update menu item, and the `AppUpdater` injection seam
  (`Sources/KeyScribeKit/AppUpdater.swift`) are built and wired. Before 1.0, decide whether the
  public app uses Sparkle and, if so, land the update contract: appcast hosting, EdDSA signing keys,
  release-note source, update cadence, failure UX, and release/preflight coverage.

### Polish
- **Mode editor visual QA.** The editor uses a progressive surface: common settings are visible,
  routing and recognition/replacements carry the remaining disclosures, cloud-boundary controls are
  grouped under "Data sent with AI", and riskier escape hatches stay TOML-only with read-only notes.
  Before 1.0, verify every seeded mode, especially long names, disabled dependency reasons, and
  small-window wrapping.
- **Accessibility / error-state / onboarding pass.** Run a real VoiceOver and keyboard pass through
  first run, Settings, HUD actions, and the correction surfaces. Pay particular attention to problem
  indicators, data-boundary badges, microphone/accessibility recovery actions, and the permission
  relaunch flow.
- **Verbatim span coverage.** Current behavior lives in `VerbatimTokenizer`: pause punctuation around
  markers is absorbed, begin-marker-glued terminators are stripped, spans do not fold into the
  previous clause, redundant post-`end verbatim` terminators collapse into the content's own
  terminator, exact `end verbatim` wins over fuzzy rescue, and misheard closes such as `"and
  verbatim"` / `"en verbatim"` are accepted. A truly unclosed span still protects to the end of the
  utterance and restores with `begin verbatim` visible. The remaining work is validation, not design:
  add real-voice `--commands-check` clips for the misheard-close cases. Keep the ambiguous content
  terminator case as-is: when STT glues a terminator to the content before `end verbatim` and there
  is no post-marker terminator to collapse against, it is indistinguishable from an intended
  terminator (`contentTerminatorIsPreserved`).

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
