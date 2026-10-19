# KeyScribe roadmap

KeyScribe's core loop is complete: on-device dictation, atomic insertion, vocabulary and spoken
edits, editable modes, local history, and optional bring-your-own-provider rewrite. The roadmap is
intentionally short. It records work with a concrete user outcome, not a running changelog.

## Next

### Release confidence

- Exercise an installed build through an update and release smoke before calling the distribution
  flow routine.
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

- A first-run practice receipt that explains successful insertion and clipboard fallback.
- Intent-first mode creation, portable mode bundles, and cancellable large-model downloads.

## Held decisions

- Speech recognition remains on-device. Rewrite is optional, provider-configured, and must never be
  described as a reliable redaction boundary.
- Recognition bias is engine-specific: keep the current Whisper/Qwen3 policy unless new distractor
  data clears a different mechanism.
- Do not automatically collect visible screen text for rewrites without new evidence that changes its
  permission and privacy trade-off.
- Prompt changes are eval-gated.
- Streaming transcription ships behind an experimental toggle (Settings > Maintenance) and stays
  opt-in until it is proven to preserve commit-on-release insertion in ordinary use.
- Voice commands ship behind the experimental `voice_commands` toggle. Remove the flag only when:
  - Recorded voice-command phrases ("switch to …", "open …", "run …", "go back") resolve correctly
    on the recommended speech model. No corpus covers these phrases yet, so record one first.
  - The Voice Commands editor, Try it, the choice list, and the HUD outcomes have had a hands-on
    review against [`ui_design.md`](ui_design.md) §7, including keyboard and VoiceOver.
  - Saved web places work in each browser that can list tabs, including a denied grant and the first
    command after install, which waits on the Automation prompt and then reads the tabs. A command
    given while that prompt is still unanswered says the browser is waiting for permission, not that it
    could not list its tabs.
  - A hung browser has been measured against the next command, and its stall on the shared
    AppleScript queue is either accepted or removed by giving each browser its own queue.
  - Rolling out makes every gate unconditional. Find them by searching for `.voiceCommands` and
    `voiceCommandsEnabled`; the system mode must then be seeded and shown for every user.
  The grammar stays English-only, with replacements as the escape hatch. The rule that Voice Commands
  needs its own shortcut can be relaxed later by splitting tap and hold on one key.

## Later, only with a demonstrated need

- OCR for sparse-Accessibility apps, but only with an explicit Screen Recording trust decision.
- Diarization and batch transcription.
- Cross-platform support.

## Invariants

- Preserve the local-first privacy boundary and no-telemetry posture.
- Keep the default path simple; advanced controls are progressive disclosure, not first-run chores.
- Migrate persisted configuration forward safely.
- Test pure behavior before implementation and verify user-facing changes in the app.
