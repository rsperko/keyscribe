# KeyScribe — Build Status & Remaining Work

> Companion to `design.md`. The full feature set ships: the whole pipeline works end-to-end —
> local dictation → modes (Phase-A app/URL/window-title routing + Phase-B trigger-phrase routing + per-mode
> trigger keys) → dictionary / replacements / live edits / numbers / fuzzy → optional **BYOK
> rewrite** → **verbatim + redaction wedge** (secrets tokenized before any cloud call, restored
> locally) → atomic insert. Plus edit-in-place, 7 STT engines with bias, the Settings UI
> (General · Speech Models · Vocabulary · AI Services · Modes · Permissions · Advanced), local
> history with the correction surface, and the standalone correction panel.
>
> What follows is the work that is **not** done.

---

## Remaining work

### Distribution & updates
- **Notarization** (Developer ID, hardened runtime). `KeyScribe.entitlements` exists but is dormant
  — `make-app.sh` does not pass it yet. A `Developer ID` cert is required.
- **In-app updates (Sparkle)** + the menu-bar **update badge** (blue dot, top-right —
  `ui_design.md` §6) and the **Check for Updates…** menu item. None built yet.

### Platform floor (investigation — not yet scoped to a version)
- **Identify KeyScribe's actual minimum macOS version.** `Package.swift` pins `.macOS("26.0")`, but
  the real floor is unverified — most of the app almost certainly runs lower, and the 26 pin is the
  largest single limit on install base. Scope the investigation: (1) availability-gate the Apple
  **SpeechAnalyzer** engine (`@available`) instead of pinning the whole app to 26 — the other engine
  kinds (Parakeet/Whisper/Qwen3/Moonshine) are not OS-version-bound the same way; (2) audit each STT
  dep's own deployment floor (FluidAudio, the WhisperKit fork, speech-swift/MLX, the Moonshine
  xcframework); (3) audit SwiftUI/AppKit API usage for the `@available` markers needed below 26;
  (4) define the test matrix for the chosen floor. Outcome: the lowest floor supportable without
  dropping a non-SpeechAnalyzer capability.

### Polish
- **Progressive-disclosure pass.** The Mode editor's top-level basic/advanced split is not done
  (the editor keeps its existing disclosure sections). General settings have a partial pass.
- **Accessibility / error-state / onboarding polish.** Partial: the error HUD offers a repair action
  on a mic failure, and first run has **Skip for now** on the model + permissions steps. More to do.

### Settings-editor follow-ups
- Per-keystroke config writes → an explicit **Save** in the mode/connection editors.

### AI rewrite
- **Connection-UX research** (`principles.md` §5): study the cleanest LLM-connection UX (e.g.
  LibreChat) and refine the AI Services pane against it.
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
