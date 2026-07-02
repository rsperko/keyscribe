# KeyScribe — Build Status & Remaining Work

> Companion to `design.md`. The full feature set ships: the whole pipeline works end-to-end —
> local dictation → modes (Phase-A app/URL/window-title routing + Phase-B trigger-phrase routing + per-mode
> trigger keys) → dictionary / replacements / live edits / numbers / fuzzy → optional **BYOK
> rewrite** → **verbatim + redaction wedge** (recognizable sensitive spans best-effort tokenized
> before any cloud rewrite, restored locally) → atomic insert. Plus edit-in-place, up to 8 STT
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
- **In-app updates (Sparkle)** + the menu-bar **update badge** (amber dot, top-right —
  `ui_design.md` §6) and the matching update menu item. None built yet.
- **Release packaging floor alignment.** The app bundle and `Package.swift` declare macOS 15.0, and
  Apple Speech is availability-gated to macOS 26+, but the Homebrew cask currently declares macOS
  Tahoe. Decide whether the cask should relax to the app floor before the next publish.

### Polish
- **Visual/UI polish.** The Mode editor now uses a simpler progressive surface: common settings are
  visible, routing and recognition/replacements carry the remaining disclosures, and riskier escape
  hatches stay TOML-only with read-only notes. Still needs visual QA across the seeded modes and an
  accessibility pass.
- **Accessibility / error-state / onboarding polish.** Partial: the error HUD offers a repair action
  on a mic failure, and first run has **Skip for now** on the model + permissions steps. More to do.

### Settings-editor follow-ups
- Per-keystroke config writes → an explicit **Save** in the mode/connection editors.

### AI rewrite
- **AI Services polish:** the pane now uses progressive sections for service, endpoint,
  authentication, model discovery, and connection test. OpenAI-compatible endpoints support no auth,
  a Keychain-backed API key, or a command-generated bearer token. Remaining polish is narrow: long
  discovered model names can make the native picker wide, and the unsaved-key state needs continued
  visual QA.
- A cached post-install **self-test-failed** model flag (needs persisted state) to broaden the error
  badge's coverage.
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
- **Privacy invariant:** nothing leaves the device except explicit BYOK rewrite calls; **no
  telemetry/analytics**.
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
