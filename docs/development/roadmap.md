# KeyScribe roadmap

KeyScribe's core loop is complete: on-device dictation, atomic insertion, vocabulary and spoken
edits, editable modes, local history, and optional bring-your-own-provider rewrite. The roadmap is
intentionally short. It records work with a concrete user outcome, not a running changelog.

## Next

### Release confidence

- Exercise an installed build through an update and release smoke before calling the distribution
  flow routine. The release mechanics live in
  [`agent_notes/distribution_plan/`](../../agent_notes/distribution_plan/).
- Continue visual and keyboard/VoiceOver checks of first run, the menu bar, Settings, HUD, History,
  and error recovery. The interaction contract is
  [`ui_design.md`](ui_design.md); treat it as the source of truth rather than historical UI plans.

### Make the writing loop better

- Improve starter rewrite wording through the eval harness. For example, Cleanup should describe
  filler words as examples rather than an exhaustive list.
- Keep connection and model-management surfaces readable with real long names and degraded states.
- Consider prompt-layout slots only if a concrete power-user workflow needs them; preserve the fixed
  trust boundary between instructions and untrusted context.

### High-value product gaps

- A quiet diagnostics/readiness pane that explains whether dictation can work now and names the next
  recovery action.
- A first-run practice receipt that explains successful insertion and clipboard fallback.
- Intent-first mode creation, portable mode bundles, and cancellable large-model downloads.

Acceptance criteria and non-goals for these are in
[`agent_notes/improvement_ideas/improvements.md`](../../agent_notes/improvement_ideas/improvements.md).

## Held decisions

- Speech recognition remains on-device. Rewrite is optional, provider-configured, and must never be
  described as a reliable redaction boundary.
- Recognition bias is engine-specific: keep the current Whisper/Qwen3 policy unless new distractor
  data clears a different mechanism. See
  [`agent_notes/decisions/recognition_bias.md`](../../agent_notes/decisions/recognition_bias.md).
- Do not automatically collect visible screen text for rewrites without new evidence that changes its
  permission and privacy trade-off. See
  [`agent_notes/decisions/screen_context.md`](../../agent_notes/decisions/screen_context.md).
- Prompt changes are eval-gated; see
  [`agent_notes/decisions/prompt_evaluation.md`](../../agent_notes/decisions/prompt_evaluation.md).

## Later, only with a demonstrated need

- Streaming transcription as a latency optimization that preserves commit-on-release insertion.
- OCR for sparse-Accessibility apps, but only with an explicit Screen Recording trust decision.
- Diarization and batch transcription.
- Cross-platform support.

## Invariants

- Preserve the local-first privacy boundary and no-telemetry posture.
- Keep the default path simple; advanced controls are progressive disclosure, not first-run chores.
- Migrate persisted configuration forward safely.
- Test pure behavior before implementation and verify user-facing changes in the app.
