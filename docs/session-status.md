# Session status

Running handoff log — read first. The autonomous phase built M2–M6 logic; the **interactive phase**
then verified the whole pipeline live, wired the deferred runtime pieces, and added infra/fixes.

Last updated **2026-06-21**: M2–M6 pipeline verified live end-to-end (BYOK rewrite + redaction wedge,
edit-in-place, per-mode keys). A long interactive pass got **recognition bias working live on all four
models** (two Parakeet tiers, Whisper, Apple): **WhisperKit 0.9.4 → fork of v1.0.0** with the #372
empty-output fix; **Apple switched to `DictationTranscriber`** (the only module that honors
`contextualStrings`); **Parakeet bias re-implemented via FluidAudio's NeMo CTC-WS** on a fork (the old
blind post-STT rescorer stays removed). A follow-on pass then built and **verified live** the Speech
Models **install flow** — download-progress UI, post-install **self-test**, and launch-time marker↔disk
**reconcile** (`ModelMaintenance` / `ModelSelfTest` / `ModelLoadProgress` / `ModelSelfTestRunner`).
A later pass then built the **Settings UI** (see "Settings UI — built" below): the previously deferred
mode editor, BYOK connections, and Dictionary/Replacements panes now all ship, the global hotkey was
replaced by per-mode trigger keys, and a menu **Dictate with** submenu + HUD **Insert local transcript**
escape hatch landed. Remaining: the standalone correction-panel shortcut, two Settings-editor
follow-ups, and the rest of M7.

## Input Monitoring permission: wrong TCC subsystem + stale-grant footgun (2026-06-22, uncommitted)

**Symptom:** Input Monitoring showed orange "Needs attention" while the System Settings toggle was on
and the hotkey actually worked. Verified live fixed (all permission rows green, hotkey starts dictation).

**Root-cause code bug (this ships):** `Permissions.swift` checked/requested Input Monitoring via the
**IOHID** subsystem (`IOHIDCheckAccess`/`IOHIDRequestAccess`, `kIOHIDRequestTypeListenEvent`), but the
app listens for keys through a **`CGEventTap`** (`HotkeyMonitor`, `.listenOnly` `.cgSessionEventTap`),
whose permission lives in Core Graphics' **ListenEvent** TCC service. The two subsystems can disagree —
IOHID reported denied while the CG-level tap was authorized and functioning. Fixed by switching to the
APIs that match the mechanism: **`CGPreflightListenEventAccess()`** (check) / **`CGRequestListenEventAccess()`**
(request). Rule of thumb: **query the permission API that matches how you consume the input** — CGEventTap
⇒ CG ListenEvent, not IOHID.

Supporting changes (all uncommitted):
- **`Resources/Info.plist`** — added `NSInputMonitoringUsageDescription` (declaration for an input-
  monitoring app; ships in the bundle via `make-app.sh`).
- **`PermissionsSettingsView` / `FirstRunController`** — the request now `NSApp.activate(...)`s first and
  **no longer immediately deep-links to System Settings** (that focus-steal pre-empted the consent
  dialog). The pane shows the **Allow** button in the *denied* state too (`requestableWhenDenied`),
  because `CGPreflightListenEventAccess` is a bool → only ever `.granted`/`.denied`, never
  `.notDetermined` (unlike Microphone/AVCapture).
- **`AppDelegate.startListening`** — only creates the tap once `inputMonitoringStatus() == .granted`
  (no doomed speculative tap when ungranted). Requesting stays owned by onboarding + the Settings Allow
  button, so launch doesn't prompt out of sequence.

**The footgun that ate the session (dev-env, NOT a shipping bug):** years of rebuilds left **stale TCC
grants bound to older code signatures**. The vicious part: a **stale Accessibility entry** (toggle on,
but its stored `csreq` no longer matched the current binary, so `AXIsProcessTrusted` returned false)
was **silently suppressing the Input Monitoring prompt** — TCC's prompt logic saw "client already has
Accessibility → skip the IM prompt", so `CGRequestListenEventAccess()` no-opped every time even from a
freshly-`tccutil reset` ListenEvent state. The cure was resetting **both** services so neither had a
stale record, then re-granting fresh:
`tccutil reset Accessibility com.keyscribe.app && tccutil reset ListenEvent com.keyscribe.app`. A fresh
notarized install has no stale entries, so the prompt fires and auto-registers normally — users won't
hit this; it's a dev-machine artifact.

**Diagnostic facts proven this session (don't re-derive):**
- `IOHIDCheckAccess(ListenEvent)` returns **Denied, never Unknown**, for a never-granted app on macOS 26
  (so it never surfaces "not determined"). `CGPreflightListenEventAccess()` is a plain bool.
- TCC verdicts (`IOHIDCheckAccess`, `AXIsProcessTrusted`, `CGPreflightListenEventAccess`) are **read at
  process launch and cached for the process lifetime** — a grant/revoke needs an app **relaunch** to
  register. "Toggled on but app says missing" almost always = needs relaunch *or* a stale-signature entry.
- Toggling an app off→on in the System Settings list **does not rebind** its `csreq`; only remove+re-add
  (the "−"/"+" buttons) or `tccutil reset` re-binds the grant to the current signature.
- The system TCC.db (`/Library/Application Support/com.apple.TCC/TCC.db`) is **not readable even with
  `sudo`** (SIP `authorization denied`) unless Terminal has Full Disk Access — don't waste time on it.
- Signing is verified **stable**: one `KeyScribe Local` identity, leaf SHA1 `E7F0D9B0…` == the bundle's
  designated requirement; every `make-app.sh` re-signs with it, so grants persist across rebuilds *for
  the current cert* (stale grants are from earlier certs/ad-hoc/Stenoir-era builds).

## Correction panel + error badge + recording tint (2026-06-22, uncommitted working tree)

Three user-requested features. `swift build` clean; full `swift test` passes (371; +2 new Settings
schema tests). **UI not yet verified live** — needs an interactive pass (menu items, panel layout,
red glyph while recording, red dot on a problem state).

- **Standalone correction panel** (`CorrectionPanelController`, new) — closes the long-deferred M3/M7
  item. **Add Dictionary Entry…** / **Add Replacement…** in the menu bar (`MenuBarController`) and via
  **optional global shortcuts**. A small titled window (SwiftUI) writes to the global
  Dictionary/Replacements stores (reusing `adding(word:)` / `addingLiteral` via `AppDelegate`
  helpers shared with the History correction surface); the FSEvents watcher reloads live. The
  Heard/term field is **pre-filled best-effort from the current selection** — `captureSelection()`
  runs *before* `NSApp.activate`, so the synthetic ⌘C still reaches the app the user was in.
- **Optional global shortcuts** — new `[shortcuts]` table in `Settings` (`add_dictionary_entry` /
  `add_replacement`, empty = off, no schema bump; decode/encode tested). Edited in **Settings ▸
  General** via the existing `HotkeyRecorder`. `HotkeyMonitor` gained **action bindings**: chord-only,
  fire `onAction(id)` once per press (an `engaged` set debounces keyDown auto-repeat, cleared on
  keyUp). `AppDelegate.buildHotkeyMonitor` builds them from settings and skips unparseable / non-chord
  strings.
- **Chord triggers are now suppressed (2026-06-22).** `HotkeyMonitor`'s tap is **active**
  (`.defaultTap`, falling back to `.listenOnly` when an active tap can't be created without
  Accessibility). `handle` returns a consume flag and `consume(type:keyCode:flags:)` swallows an exact
  chord match — mode trigger or action chord — on key-down, tracks the base keyCode in
  `suppressedKeyCodes`, and swallows the matching key-up only if it swallowed the key-down (so typing
  the base key *alone* still passes through, no stuck key). Modifier-only named triggers (flagsChanged)
  are never consumed. **Fixes the edit-in-place footgun**: a chord like ⌃⌥E used to pass through and the
  app read Option-E as the acute-accent **dead key**, replacing the selection before the rewrite ran
  (root cause confirmed by reproduction: text deleted with no synthesized key from KeyScribe; fix
  verified — selection survives the press). Covered by `HotkeyMonitorSuppressionTests`.
  - Because the tap is now active, `onStart`/`onCommit`/`onAction` are **dispatched off the callback**
    (`dispatchSideEffect`, FIFO on the main queue): an active tap holds the event until the callback
    returns, and `handleStart` does ~200ms of real work (engine resolve, audio start, HUD). The consume
    decision and gesture *state* stay synchronous; only the side-effect is deferred (start always runs
    before its commit). This also shrinks the `tapDisabledByTimeout` window that would otherwise strand
    a hold mid-gesture.
- **Recording tint** — `DictationController.onRecordingChanged` fires true after `audio.start`, false
  on commit/cancel; `MenuBarController.setDictating` sets `button.contentTintColor = .systemRed` on
  the template glyph (reverts to nil). Idempotent, so duplicate falses are harmless.
- **Error badge (red dot, top-left)** — `MenuBarController.setErrorBadge` toggles a 6pt red CALayer-
  backed `NSView` pinned top-left of the status button (separate layer so it survives the template
  adaptation *and* the recording tint). `AppDelegate.refreshStatus` shows it for a config-load failure
  or any missing required permission. **Navigates to the cause:** a single pure mapping
  `SettingsProblem.detect(…)` (tested, KeyScribeTests) feeds *both* the menu dot and a
  `SettingsProblemModel` that flags the offending Settings sidebar pane with its own red dot
  (Permissions / Advanced); the sidebar `.task`-polls while open so the flag clears on fix. AppDelegate
  injects `detectProblems` into `SettingsController` so there is one source of truth. **Triggers now
  also cover model + AI:** unusable active STT engine (`SpeechModelsModel.activeEngineUsable`) →
  Speech Models. **AI checks (all → AI Services pane + the offending connection's row):** a **dangling**
  connection (a mode names a *deleted* connection — empty/optional connections are deliberately *not*
  flagged, else fresh installs with the AI starter modes would false-alarm); a **structural
  misconfiguration** (`Connection.configIssue`, KeyScribeKit + tested — empty model, or
  OpenAI-compatible with no base URL); and a **failed Test Connection**
  (`AIServiceSettingsModel.failedTestIds` → `SettingsController.failedConnectionIds`). A mode wired to a
  **failed** connection additionally flags the **Modes** pane and that mode's row (`brokenConnectionIds`
  passed into `ModesSettingsView`). Row styling: orange = incomplete config, red = failed test. **A
  missing key is *not* an error** — legitimate for a local/no-auth endpoint (the earlier keyless flag
  was removed per user feedback). **No passive probe** (privacy invariant); the only live AI signal is
  the user-initiated test. **Still to do (roadmap M7):** a cached post-install self-test-failed flag
  (needs persisted state).

## Hot-path hardening pass (2026-06-22, uncommitted working tree)

A behavior-preserving performance + concurrency pass over the per-dictation hot path (one UX fix is
the only behavior change). No new features, no contract changes — design/roadmap/config unchanged.

- **Per-(mode, config-generation) derived caches** (`DictationController`): the compiled post-STT
  pipeline and the merged global⊕mode dictionary are built once per mode and reused, dropped wholesale
  when `ConfigCache.generation` advances (bumped on every `invalidate()`). Previously each commit
  re-merged the dictionary three times (bias / valid-term hint / fuzzy) and rebuilt every stage. Stages
  precompute their derived tables in `init` (`FuzzyCorrector.Prepared` Soundex, `SpokenSymbols.Prepared`
  maxWords), so caching the pipeline also keeps that work off the per-dictation path.
- **Off-main, bounded AX for preceding-text** (`ContextProbe.precedingText` is now `async`): the AX walk
  runs on `Task.detached` with `AXUIElementSetMessagingTimeout(0.3)` so a wedged target can't stall the
  dictation flow; browser-URL `NSAppleScript` objects are compiled once and cached per bundle.
- **Mic-level + HUD**: RMS via `vDSP_rmsqv` (Accelerate), audio work skipped entirely when no handler;
  the HUD level is forwarded only on a *quantized* change (per-buffer → step changes) and `HUDController`
  skips a render when state is unchanged.
- **Parakeet bias caching** (`ParakeetEngine`): tokenized vocabulary + `VocabularyRescorer` cached keyed
  on the term set, rebuilt only when terms change (the rescorer reads the CTC model dir, so per-dictation
  recreation was needless I/O); removed dead `ASRError`.
- **Paste restore** (`TextInserter`): the post-⌘V wait now polls `changeCount` and bails early if anything
  wrote after our scratch (was a flat 250 ms sleep); still gated so we never clobber a newer write.
- **History**: `HistoryStore.signature()` (file count + latest day-file name/size/mtime) gates re-parse,
  so re-fronting the window when nothing changed is free; `HistorySearch.matches` filters per-entry and
  `HistoryRow` precomputes its day key. `ValidationGate` counts token occurrences by range scan (no
  `components(separatedBy:)` allocation); `RedactionTokenizer` precomputes span length for its sort;
  `LiveEditsStage` lowercases tokens once.
- **Settings**: the Permissions poll moved from a always-on `Timer.publish` to a `.task` loop cancelled
  on disappear (polls only while the pane is visible); `SpeechModelsModel.updateRow(id)` rebuilds just the
  changed row per download-progress tick instead of reconstructing (and re-statting) every row.
- **UX fix (the one behavior change):** *Work on Selection* now checks Accessibility before the synthetic
  ⌘C selection capture — without it the read silently fails and the old abort misreported "no selection."
  It now names the cause ("Accessibility is off — KeyScribe can't read the selected text.") and offers an
  **Open Accessibility Settings** repair action (`HUDErrorAction.openAccessibilitySettings`).

## GPT UI-review fixes — M7 polish (2026-06-22, uncommitted working tree)

Worked `agent_notes/gpt_ui_review/review.md` against the live app (a UX pass comparing the build to
`ui_design.md` / `ui_components.md`). Every claim was checked against source first; one was an
overstatement (History "Create Replacement" was already pre-filled). **`swift build` clean; full
`swift test` passes; HUDStateTests now 10/10** (5 added for the new pure logic). A live visual pass
(drive-with-AppleScript + `screencapture` + read) confirmed the static surfaces; the conditional/
transient ones are noted below as still-needing a live trigger.

**First run (P0 — was a dead end):** `FirstRunView` now offers a low-prominence **Skip for now** on the
**model** and **permissions** steps (previously only on the final trial step), each with an in-place
limitation note. Taking it calls `model.finish()` = setup complete, per `ui_design.md` §2. *Verified
live:* the model-step skip + caption render and the click dismisses the wizard.

**Settings resizable (P0):** `SettingsController` window gains `.resizable` + a `minSize` (760×520) and
`SettingsRootView` swaps its fixed `.frame` for `minWidth/idealWidth…`. *Verified live* (resized to
1180×1000).

**Inline help / truthful labels (P1/P2, `ModesSettingsView`):** converted the under-explained controls
to `SettingRow` (outcome + Learn-more): *Work on selection*, *Recognize spoken edits*, *Use global
dictionary*, *Use global replacements*; added a default-mode caption. Renamed **"Send app & field
details" → "Send app details"** (the only call site passes `fieldRole: nil`, so no field role is ever
sent). Insertion-method row now shows an Accessibility `dependencyReason` + **Open Accessibility
Settings** when Insert/Type is picked without AX. *Verified live* (AX-dependency correctly hidden while
granted).

**Shared data-boundary badge (P2):** new `DataBoundaryBadge` in `SettingsComponents.swift`, fed by the
centralized `HistoryEntry` label strings. Replaced the two duplicated History badge views and wired it
into the **HUD** (`.rewriting` now shows discrete badges instead of a collapsed text line via
`HUDState.dataBoundaryBadges`). *History badges verified live; HUD rewriting badges still need a live
cloud rewrite.*

**History corrections scope-aware (P1):** `HistoryController` pre-fills the dictionary **term** when the
result is a single word, states scope explicitly ("Adds to your **global** dictionary/replacement…"),
and previews the resulting replacement rule. Empty state gained an **Open History Settings** button
(wired through `AppDelegate`). *Corrections captions verified live; empty-state link only renders with
zero entries.*

**Error HUD action (P2):** `HUDState.error` now carries an optional `HUDErrorAction`; a mic-start failure
offers **Open Microphone Settings** (and stays up 8s, not 2s). Deliberately **no generic Retry** — the
wav is deleted on failure, so retry would mislead. *Still needs a live mic-denied dictation to see.*

**Deferred (still open):** P1-3, the Mode editor's top-level basic/advanced split — the most invasive
item, overlaps the M7 progressive-disclosure pass; the two existing `DisclosureSection`s remain. See the
roadmap M7 checkboxes (progressive-disclosure / accessibility-error-onboarding now marked partial).

## Scribe-comparison hardening pass (2026-06-22, uncommitted working tree)

Ported the high-value lessons from the older `shopify-playground/scribe` predecessor (a read-only
comparison report), skipping everything that violates KeyScribe's invariants (cloud STT, screen OCR,
shell key-commands, local-endpoint redaction bypass). **`swift test` = 353 tests / 51 suites pass**;
full app target compiles. Ten of eleven items landed; per-engine ASR-confidence + HUD preview deferred
(needs a live session — see end).

**Pure logic (KeyScribeKit, TDD red→green):**
- **Redaction breadth + checksums** (`RedactionTokenizer`). Was 7 unvalidated regexes; now ~20 vendor
  patterns (Stripe/Slack/JWT/AWS family/Google/Shopify/GitHub PAT/PEM/Bearer/`KEY=`…) + **Luhn**-gated
  cards + **IBAN mod-97** (dedicated trim-to-valid finder, since IBANs allow letters and a greedy regex
  over-extends into the next word) + a conservative **Shannon-entropy** sweep for novel secrets.
  Over-matching is safe — a token restores to its original after the LLM.
- **Regex backtracking guard** (`ReplacementSafety`) — static nested-quantifier detector; `ReplacementsStage`
  skips an evil user pattern (`(a+)+$`) instead of hanging the hot path. (Can't time-out a synchronous
  `NSRegularExpression`, so static refusal is the only real defence.)
- **Inverse text normalization** (`InverseTextNormalizer` / `NumbersStage`, `commands.numbers`) —
  "twenty five" → "25", **bails on ambiguous/year runs** ("twenty twenty six" stays words).
- **Spoken symbols** (`SpokenSymbols` / `SymbolsStage`, `commands.symbols`) — "open paren" → "(".
- **Fuzzy correction** (`FuzzyCorrector` / `FuzzyStage`, `commands.fuzzy_correction`) — Levenshtein +
  Soundex snap to dictionary terms; multi-token windows only on exact-normalized match (so a glue word
  can't be merged away). Dictionary stays a hint.
- **Configurable voice commands** — `LiveEditsStage` generalized to a phrase→action map with defaults,
  adds a **tab** command; `LiveEditsStage()` still works for existing callers.
- **Lenient mode decode + last-known-good** — `ModeStore.load(in:previous:)` surfaces per-mode
  `LoadFailure`s and reuses the prior good copy instead of silently dropping a malformed mode;
  `ConfigCache` keeps last-known-good across `invalidate()` and logs failures (category `config`).
- **Prompt-injection hardening** (`PromptAssembler.neutralize`, from the reverse "parity" report) —
  inserts a zero-width space into any of our block-delimiter tags found inside *untrusted context*
  (window text, preceding text, app name, selection), so a crafted value can't close its block and
  inject a fake `<instructions>`. Content/instructions are not neutralized (content is echoed back).
  The hard validation gate catches dropped tokens; this catches a successful injection that produces
  clean output. (Data-fence for the edit-in-place selection deferred — needs live LLM-behavior checks.)
- GitLab `glpat-` added to the redactor; "lean protected terms" was already done
  (`DictationController` only sends dictionary terms present in the content).

**Performance (the report's remaining MEDIUM items):**
- **Bound the transcription wait** — `DictationController.transcribeBounded` races `transcribe()` against
  a duration-scaled timeout (20× real-time, ≥30s floor), so a wedged CoreML/MLX call surfaces a clean
  "Transcription timed out" HUD error instead of hanging forever. Robustness, not speed (batch can't
  salvage a partial).
- **Gate Parakeet CTC load on a non-empty dictionary** — split install vs runtime warm: `load(progress:)`
  (Settings install) still fetches + prewarms the CTC bias model; `loadIfNeeded()` (warm-on-press /
  launch preload) now loads **TDT only**. Empty-dictionary users never pay the CTC CoreML load; bias
  users get it lazily from disk inside `transcribe()` on first actual bias (no mid-dictation download —
  install already fetched it).
- **Memory-pressure eviction** — `DictationController` installs a `.critical` `DispatchSource` that
  evicts the active engine when idle (`!machine.isBusy`); an in-flight dictation keeps its engine.
  Local reaction to a local signal, no telemetry.
- Deferred then **done** (later hot-path hardening pass, 2026-06-22 — see top): vDSP RMS + HUD
  level-quantization throttle (was filed "micro," picked up with the rest of the hot-path pass).
  Still correctly **skipped** (per the report's own SKIP/CONSIDER calls):
  streaming partial transcription (conflicts with batch/atomic-insert), and `StageTimings` instrumentation
  (no consumer yet — would be dead code; revisit if/when measuring warm-on-press's payoff).

**OS edges (adapters):**
- **TextInserter pasteboard guard** — full-type snapshot/restore (`PasteboardSnapshot`, no longer
  `.string`-only, so images/RTF/files survive a dictation), ⌘C settle **polled on changeCount** (not a
  blind 120 ms sleep — the M0 "slamic…" race), paste-restore **gated on changeCount** (don't clobber a
  newer write), scratch write marked **transient + concealed** so clipboard managers skip it.
- **Warm-on-press + launch preload** — `DictationController.handleStart` fires an idempotent
  `loadIfNeeded()` so model load overlaps speech; `EvictionPolicy.preloadAtLaunch` preloads the active
  engine at launch for the Fastest profile (AppDelegate).
- **Preceding-text context** — `ai_rewrite.context.preceding_text` opt-in; `ContextProbe.precedingText()`
  reads bounded pre-caret text from the focused field's AX selected range (native-only, best-effort,
  Chromium → nil). Forced off in privacy mode like all context; assembled into a `<preceding_text>` block.

**Deferred — needs an interactive session:** ASR confidence + low-confidence HUD preview. No uniform
per-transcript confidence exists across the 7 engines today (logProbs are only in Parakeet's CTC-WS
spotter path); surfacing it means per-SDK extraction (WhisperKit segment avgLogprob, FluidAudio token
confidences, Apple/Qwen3; Moonshine has none) + HUD preview UX + threshold tuning against real
distributions — none verifiable headlessly. Left unbuilt rather than land an unwired seam + untested HUD.

Not yet verified interactively: TextInserter changes (use the clipboard-marker probe), warm-on-press
latency win, and preceding-text capture across real apps. Settings UI checkboxes for the four new
toggles (`numbers` / `symbols` / `fuzzy_correction` / `preceding_text`) are not yet wired — the fields
are functional via TOML and decode/encode round-trip.

## Custom hotkey recorder + app picker (2026-06-21, uncommitted working tree)

Two Modes-editor UX gaps closed — both **UI-only**, the model already supported them:

- **Custom hotkey recorder.** Trigger-key picker gained a **Custom shortcut…** option that reveals a
  `HotkeyRecorder` (`Sources/KeyScribe/Settings/HotkeyRecorder.swift`) — a live `NSEvent` local-monitor
  capture that serializes to the canonical descriptor string. Pure-logic seams in KeyScribeKit (TDD):
  `KeyDescriptor(eventKeyCode:modifiers:)` (chord from a captured event; nil for bare non-function /
  unknown keycode), `KeyDescriptor.displayString` (glyph rendering ⌃⌥⇧⌘), and `KeyDescriptor.collides`
  + `TriggerKeyConflicts.conflict(for:excludingModeId:in:)` driving an inline **conflict warning** when
  another enabled mode claims the same physical key. The curated named-key picker is kept as the safe
  default tier (Fn/right-Option etc. are the hold-or-tap keys; chords are the power-user escape hatch).
- **Bundle-ID app picker.** The raw "type a bundle id" text field is replaced by an **Add app rule**
  menu listing running GUI apps (+ *Choose from Applications…* `NSOpenPanel` + *Enter Bundle ID…*
  manual escape hatch), backed by `Sources/KeyScribe/Adapters/InstalledApps.swift`. App constraints now
  render with the **app icon + friendly name** (raw bundle id as a caption). URL rules keep the text
  field (the pattern is a regex). Match semantics unchanged — exact `bundle_id` equality in
  `ModeResolver`.

`swift test` = **293 tests / 42 suites pass**; `swift build` + `make-app.sh` clean. Not yet
verified interactively (recorder capture + app menu need a live Settings session).

## Settings UI — built (2026-06-21, uncommitted working tree)

The deferred Settings editors are built. The Settings window is now a **7-pane `NavigationSplitView`**
(940×640) — `SettingsDestination`: **General · Speech Models · Vocabulary · AI Services · Modes ·
Permissions · Advanced** (`SettingsController.swift`). What each new pane does:

- **Modes** (`ModesSettingsView`) — master-detail mode editor (create / edit / enable / delete, with a
  delete-confirmation dialog). Sections: *Basics* (name, enabled); *When this mode is used* (trigger-key
  picker — No dedicated hotkey / Fn / Right Option / Right Command / Hyper / **Custom shortcut…** — +
  press-style picker + **Advanced routing** disclosure for app/URL constraints and spoken trigger
  phrases); *What it does*
  (work on selection, recognize spoken edits); *Dictionary* and *Replacements* (per-mode, with
  use-global toggles, reusing the shared rows); *Improve with AI*; *Result handling* (insertion method,
  exclude-from-history); delete.
- **AI Services** (`AIServiceSettingsView`) — master-detail BYOK connections editor: name, provider
  (OpenAI / Anthropic / Gemini / OpenAI-compatible), model, `SecureField` API key saved to **Keychain**
  under `key_ref` (`keyscribe.llm.<id>`), Advanced disclosure for the OpenAI-compatible Base URL, delete
  with confirmation. `ConnectionStore` gained `write`/`newID`.
- **Vocabulary** (`VocabularySettingsView`) — global Dictionary + Replacements, via shared
  `DictionaryRows` / `ReplacementRows` (reused by each mode's own vocabulary section). `DictionarySet`
  gained `removing(word:)`.
- **Permissions** (`PermissionsSettingsView`) — its own pane (moved out of General): Microphone / Input
  Monitoring / Accessibility rows with status, purpose, Allow / Open System Settings, and Refresh.
- **Advanced** (`AdvancedSettingsView`) — Reveal Config in Finder + Reload Configuration (moved out of
  General).

**Global hotkey removed → per-mode trigger keys.** The `Settings.Hotkey` struct and `[hotkey]` config
table are gone; `tap_threshold_ms` moved onto each `TriggerKey` (default 250). `AppDelegate.buildHotkeyMonitor`
now builds bindings purely from each enabled mode's `trigger_keys` (no seeded global binding); the
`plain-dictation` starter seeds `trigger_keys = [fn]`. General settings dropped its hotkey section.

**Menu "Dictate with" + next-dictation override.** `MenuBarController.setModes(...)` builds an Automatic
item + a per-mode list + "Manage Modes…"; selecting one calls `DictationController.setNextModeOverride`,
which Phase-A applies then clears — **affects exactly one next dictation**, acknowledged by the HUD's
"Next dictation:" line (`ui_design.md` §6).

**HUD local-transcript escape hatch.** During a cloud rewrite, `DictationController` schedules a 5s
escape hatch; the HUD shows an explicit **Insert local transcript** button (`HUDState.rewriting` gained
`offerLocalTranscript`; new `.localFallback` state). Dictation-only — never for selection modes. The
HUD never auto-inserts early.

**Default STT engine flipped to the compact 110M tier.** `Settings` default `stt.engine` is now
`parakeet-tdt-ctc-110m` (was `parakeet`); `SpeechModelInfo.isDefaultEnglish` moved to the 110M, and
each catalog entry gained a `summary` line shown on its card. `SpeechModelsView` redesigned with an
active-engine banner, badges (Recommended / English|Multilingual / Compact|Large|Standard / No
dictionary bias), install size + Finder-reveal (`ModelInstallStore.presentInstallURLs`/`installedBytes`).

**First run** now requests permissions **one at a time** (`FirstRunController.nextPermission` +
`Permission` enum) and stops hardcoding "Parakeet" in the model-step copy. **History** sidebar gained
loading / empty / no-match states and renders data-boundary badges (`HistoryEntry.dataBoundaryLabels`/
`contextLabels`).

### Settings UI polish pass (2026-06-21, this session)

A round of UX fixes on the panes above, plus a small shared-component file (`SettingsComponents.swift`):

- **`DisclosureSection`** — a collapsible whose **entire label row toggles** (not just the chevron);
  adopted for *Advanced routing* (Modes) and *Advanced connection settings* (AI Services).
- **`PromptEditor`** — bordered multi-line `TextEditor` (replaces the cramped 3-line field for the mode
  writing instruction) with an **"Open in a larger editor…"** sheet for long prompts.
- **Bordered add-fields** (`.roundedBorder`) so the previously near-invisible text fields in Advanced
  routing and the Dictionary/Replacements add-rows are visible against the grouped background.
- **Reusable instructions = a fragment picker** — replaced the free-text "fragment id" field with a
  menu of the actual `*.md` files in `<supportDir>/fragments/` (already-added ones filtered).
- **AI rewrite on/off = the service picker.** Removed the separate "Improve with AI" / "Turn Off AI
  Rewrite" buttons; the *AI service* picker now includes **"Don't use AI (on this Mac)"** as the off
  state (selecting a service seeds the default prompt; selecting off clears `ai_rewrite`).
- **Speech Models Test feedback** — a manual *Test* now shows a transient green **"Passed its
  self-test"** (`SpeechModelsModel.verifiedOk`, auto-clears) + a help tooltip; mirrors the red fail label.
- **Green permission checkmarks** — the granted state shows a green filled checkmark, matching First Run
  and the "Installed"/"In use" green checkmarks elsewhere.

**2026-06-21 (AX-coverage probe + Electron AX wake + perf cleanups measured):** a planning pass that
turned three open questions into closed ones. (1) **AX-coverage probe run** over 12 real apps — OCR
hard-defer **holds** (the only true-canvas apps are niche dictation targets); surfaced that VS Code /
Claude desktop return empty *cold*. (2) **Electron AX wake — implemented**: `AXVisibleText.capture`
now does a zero-regression wake-on-empty retry (`AXManualAccessibility`) for lazy-AX Electron apps —
not OCR, rides the existing grant; pending one live confirm. (3) **Profiling-gated perf cleanups
measured** via a new opt-in `PerfBenchmarkTests` — all four real but irrelevant at realistic sizes;
tried the one plausible token-gate fix, measured no gain, reverted. (4) **Selection-into-context →
CLOSED** (decided no, off the backlog). (5) **Upstream-PR TODOs → deferred to distant future.** See
the dedicated sections below for each. Clean build; 35 token/gate tests green.

**2026-06-21 (per-mode insertion — live-verified + AX data-loss bug fixed):** all three methods
verified live via a throwaway right-Option test mode. `type` types char-by-char; `insert` and `paste`
land correctly. **Live testing caught a silent-data-loss bug:** AX `insert` dropped text on
Chromium/Electron (Chrome, VS Code/Antigravity) with nothing on the clipboard — confirmed by a
clipboard-marker probe (marker untouched, text gone). Root cause: `AXUIElementSetAttributeValue(
kAXSelectedText)` returns `.success` on Chromium but no-ops the set, so we skipped the paste fallback.
Fix: `TextInserter.insertViaAX` no longer trusts the return — it reads `kAXValue` back and only keeps
the AX path if the field actually changed, else falls back to paste. Re-verified: Chrome now lands
text (paste), TextEdit lands via AX, clipboard saved/restored through the fallback. (Unified-logging
`log show`/`log stream` would not surface the app's os_log on this machine; the clipboard-marker probe
was the reliable ground-truth method.)

**2026-06-21 (per-mode insertion — all 3 methods wired):** `mode.insertion` was modeled but inert
(paste hard-coded). Now `TextInserter.perform(decision, method:, text:)` dispatches via a new pure
`insertionAction(decision:method:)` in KeyScribeKit: `paste` → ⌘V paste, `insert` → **AX set selected
text** (degrades to paste when a value read-back shows the field did not change — Chromium/Electron
return a false `.success`; see the entry above), `type` → **synthesized Unicode key events**
(best-effort, no success signal so no fallback). The focus-race `clipboardFallback` overrides
whichever method the mode picks — verified by `clipboardFallbackOverridesEveryMethod`.
`DictationController` passes `activeMode?.insertion`. The pure mapping is unit-tested (2 new tests);
AX/type actuation is now **live-verified** (entry above). The mode-editor UI to set the field per
mode is now built — Modes ▸ *Result handling* (see "Settings UI — built").

**2026-06-21 (engines + benchmark + framework refactor — uncommitted working tree):** added **three new
STT engines** — **Qwen3-ASR 0.6B + 1.7B** (MLX, via `rsperko/speech-swift` fork `96273cd`, product
`Qwen3ASR`; native bias through `Qwen3DecodingOptions.context`) and **Moonshine Base EN** (ONNX Runtime
xcframework, `moonshine-ai/moonshine-swift` `0fb16cc`; **no on-device bias** → `supportsRecognitionBias
= false`, badged "No dictionary bias" in Settings). All three **downloaded, self-tested, and run live
in-app** (install marker now lists them). The speech-swift fork only gates its `AsrBenchmark`/`AudioServer`
targets behind `BUILD_ALL` to avoid an argmaxinc/WhisperKit duplicate-target collision with our WhisperKit
fork. **`make-app.sh` now builds + bundles + signs `mlx.metallib`** (a hard runtime requirement for the
MLX engines, not an optimization); **Metal Toolchain** is a build-time prereq.
- **Engine framework refactor** (behavior-preserving, verified by identical benchmark numbers): single
  **`EngineRegistry`** descriptor SSOT (provider, download closure, install store, benchmark all derive
  from it — kills the parallel-list drift that had silently zeroed a benchmark run); `load(progress:)`
  moved onto the `SpeechEngine` protocol with a default (`ModelLoadProgress` moved to KeyScribeKit); install
  footprint/integrity moved onto each engine (`installDirNames` / `installState`), so `ModelInstallStore`
  is generic — removed the hardcoded `subdirs`/`markerTrustedIds`/`parakeetPrimary` maps (this had caused
  a Qwen3 reconcile dir-mismatch bug, now fixed); shared `AudioDecoder`; unified `EngineError`.
  `FirstRunController`/`AppDelegate` dropped concrete engine types.
- **STT benchmark harness** — `KeyScribe --benchmark <dir> [--engines a,b]` (headless; `BenchmarkRunner` +
  pure `BenchmarkScoring`/`BenchmarkManifest` in KeyScribeKit, TDD'd). Drives the real adapters over recorded
  clips: WER (biased vs unbiased), bias term recall, RTF. 16-clip real-voice corpus (`benchmark/`,
  gitignored): **Qwen3-1.7B 0.8% WER / 100% recall** (best), 0.6B 1.5% (fastest, RTF 0.012), Parakeet
  v3 3.0% (only one under 100% recall — CTC-WS at 84.6%), Whisper 3.2%,
  Moonshine 15.2% (bias-less). Bias is decisive.
- **Parakeet 84.6% recall TODO — INVESTIGATED, not tunable (2026-06-21).** The two steady-state misses
  are clip 05 (the `KeyScribe` app-name coinage, TDT misheard the vowels) and clip 10 (`tachycardia`/`dyspnea`, TDT heard
  "tachnicardia"/"dyspenia"). Swept every CTC-WS dial on the real corpus: `cbw` 4.5→300, `minSimilarity`
  0.5→0.4, `marginSeconds` 0.10→0.50, `spotterRescue` on/off — **none recover either clip.** Root cause is
  acoustic, not threshold: the rescorer's accept gate is `vocabCtcScore + cbw > originalCtcScore`
  (`VocabularyRescorer+TokenEvaluation.swift`), and the correct keyword token sequence won't align to the
  mangled 0.6B frames, so `vocabCtcScore` is effectively −∞ — there is nothing finite for `cbw` to lift
  (cbw=300 still keeps the original). Forcing a swap would mean blind string substitution, the exact
  corruption mode the design forbids (the removed rescorer: `Yeah`→`Bayes`). So FluidAudio defaults are
  kept unchanged; 84.6% is the 0.6B acoustic floor on this corpus (cold first-run occasionally shows
  92.3% — a CoreML warmup float artifact, clip 05 flips). Recall-critical users pick Qwen3 (100%), which
  is the recommended default anyway. Diagnostic: `KEYSCRIBE_BENCH_VERBOSE=1 KeyScribe --benchmark benchmark
  --engines parakeet` prints per-clip misses (want/bias/plain).
- **NVIDIA Canary-Qwen: dropped** by decision (a community CoreML conversion now exists on HF —
  `phequals/canary-qwen-2.5b-coreml-*` — if ever revisited, it's a normal registry add).
- **Build/test:** `swift build` + release `.app` clean (no warnings); `swift test` = **260 tests / 40
  suites pass** (added `BenchmarkScoringTests`).
- **Upstream-PR TODO (distant future — drop the pin):** `rsperko/speech-swift` BUILD_ALL gating could go
  upstream to `soniqo/speech-swift` so consumers can take just the `Qwen3ASR` product without the
  WhisperKit collision. Deferred with the other two fork-pin PRs (see the deferral note below).

## Visible-text context — BUILT + live-verified (2026-06-21)

The M5 visible-text context feature (design.md §4.4): when a mode opts into **visible text**, the
surrounding on-screen text is captured and sent to the LLM rewrite as fenced context. Research →
spike → test-first build → live-verify. **271 tests pass; clean release build.**

- **Spike finding (retired the load-bearing unknown — don't re-derive).** Extended `spikes/spike-ax`
  with a cold-walk → wake → settle → warm-walk experiment, run live across Notes/Safari/Chrome/
  Antigravity(Electron). **On macOS 26, a trusted AT reads the AX tree *cold*** — Chrome 1452 chars,
  Electron 1380 chars, <90ms, **zero fill over a 2.5s poll**. The documented Chromium "wake"
  (`AXManualAccessibility` on the app element / `AXEnhancedUserInterface` on the window) is **rejected
  as unsupported and changes nothing** here — the research's "lazy tree" gotcha does **not** apply. The
  real constraints turned out to be (1) **latency** (native Notes ~1.3s vs ~80ms browsers → capture
  must be off-main + bounded) and (2) **over-capture** (a whole-window walk grabs sidebars/nav/file-
  trees → scope to the content region). **OCR was evaluated and deferred**: AX covers native/WebKit/
  Chrome/Electron; OCR only helps canvas/sparse-AX apps (Figma, Gmail SPA) and costs the Screen
  Recording grant + purple indicator — a later, mode-gated fallback, not v1.
- **Capture adapter** (`AXVisibleText` in `Adapters/ContextProbe.swift`, `ContextProbe.visibleText`):
  reads the AX tree, **scopes to the largest scrollable content region** (`AXScrollArea`/`AXWebArea`,
  preferring the one holding the focused element) so chrome is excluded, falls back to the whole
  window. Runs **off the main actor** (`Task.detached`, pid in / `String?` out — no non-Sendable
  crossing) with a 0.3s messaging timeout, 0.7s wall-clock deadline, node/depth caps, `CFEqual` cycle
  guard, bounds-intersection filter, and visible-range extraction for text areas. **Rides the existing
  Accessibility grant — no new TCC permission.** Live-verified capturing the right region across
  Notes/Chrome/Electron.
- **Budget** (`ContextBudget.fit`, KeyScribeKit, test-first): instructions/content never truncated,
  visible text capped (`visibleTextCap` 4000) / dropped, **refuse** if mandatory content alone exceeds
  budget. Disposition (absent/kept/truncated/dropped) logged at `Log.context.notice`.
- **Context fence — tuned against ground truth (`prompt_design.md`).** The first live test exposed the
  LLM **reproducing** captured context into the output. Rather than eyeball-iterate, pulled the exact
  failing prompt from history and **replayed it against the Qwen3-Coder-30B floor (oMLX), 20+ samples/
  variant at temp 0.2 + 0.7**, measuring leak *rates*. The naive "use context to match names/tone"
  framing **leaked ~60%** on instruction-like content **and bleed-invented a recipient name on a
  legitimate rewrite** — the intended *benefit* of context is inseparable from the bleed on a weak
  model. The shipped reframe (lead with the positive task + "return unchanged if clean"; context is
  background, never to be output; any context in output = "a mistake"; drops the match-names purpose)
  measured **0/20 and 0/15**. **Design consequence:** controlled terminology/name matching belongs in
  the **`validTerms`/Dictionary** channel; raw visible-text context is situational grounding only,
  fenced from output. This is a **quality** failure, not privacy — output inserts **locally**; the
  cloud already had the opted-in context and the redaction wedge still guards secrets.
- **Mode-editor toggle — now built:** Modes ▸ *Improve with AI* ▸ "Send visible window text" sets
  `visible_text` (no longer TOML-only); the privacy toggle forces it off. A throwaway `Context Test`
  mode (`with context` suffix) was used for live-verify — delete it before shipping.
- **OCR context fallback — VETTED, hard-defer (2026-06-21).** OCR is not a new feature — it's a
  *coverage fallback* for visible-text context, capturing the same on-screen-text signal only in apps
  whose AX tree comes back empty. Its value is a product of weak links: AX already reads cold across
  native / WebKit / **Chrome / Electron** (spike-ax), so the gap is just canvas + image/PDF-as-pixels
  + a few poor-AX web SPAs (Figma, Gmail web); the context signal itself is **narrow** (see the
  selection-into-context finding); and OCR's output is *dirtier* than AX (flat pixels, no
  content-region scoping → grabs nav/chrome). The cost is **brand-damaging**: the Screen Recording
  TCC grant lights the always-on purple menu-bar indicator, which undercuts a privacy-first app's
  core promise. Verdict: narrow-value signal × niche app set × trust-costly permission → **hard-defer**,
  revisit only if a real user's daily dictation apps turn out to be canvas/poor-AX (the one input
  that could flip it).
  - **AX-coverage probe — RUN, OCR-defer HOLDS (2026-06-21).** Added `runCoverageProbe` to `spike-ax`
    (`⌃⌥⌘G` → CSV verdict per app: chars/nodes/web/role; GOOD ≥300 chars, SPARSE 50–299, EMPTY <50).
    Swept 12 real apps. **GOOD** (AX covers, OCR adds nothing): Ghostty, Messages, WhatsApp, Google
    Chrome, Google Gemini (web app, 4457 chars), Antigravity IDE (Electron, 1061 cold). **SPARSE:**
    Brave 98 chars — content-dependent, not an AX gap (Chrome/Gemini prove Chromium reads fine).
    **EMPTY:** Photos (25) and VMware Fusion (0, AXWindow) are genuine pixel/canvas — but **niche
    dictation targets**, so the Screen-Recording cost still isn't justified → defer holds. VS Code (0)
    and Claude desktop (0) returned EMPTY **cold** even though Antigravity (also Electron) read fine
    cold — a *new* nuance the earlier spike (only tested Antigravity+Chrome) missed.
  - **Electron AX wake — IMPLEMENTED, pending live confirm (2026-06-21).** VS Code / Claude returned
    empty *cold* because lazy-AX Electron apps only expose their tree once an AT asks. `AXVisibleText.capture`
    now does a **wake-on-empty retry**: if the cold read yields nothing, it sets Electron's documented
    `AXManualAccessibility` on the app element and re-reads under a longer `wakeDeadline` (1.0s). **Strictly
    safe / zero-regression:** the wake only fires when the cold read already returned nil, so apps that read
    cold (browsers/native/Antigravity) are never touched, and it's a harmless no-op (`-25205 unsupported`)
    on non-Electron. The wake persists, so even if the first post-wake read is too early for the tree to
    build, the next dictation reads cold. **Not OCR — rides the existing Accessibility grant.** Clean build.
    **Needs one live confirm:** dictate-with-context (or `⌃⌥⌘T` in `spike-ax`) in VS Code / Claude desktop
    and check the tree now returns text. If the 1.0s budget proves too short for the first woken read,
    bump `wakeDeadline` (the persisted wake means it self-heals on the 2nd try regardless).
- **Selection-into-context for edit-in-place — CLOSED, don't build (2026-06-21).** Settled and off
  the backlog (not a deferred feature — a decided no). The
  `selectedText` prompt slot just duplicates `<content>` (in edit-in-place the selection *is* the
  text being rewritten), so the only real lever is surrounding-doc context (`visibleWindowText`,
  i.e. flipping `visible_text` on a `source=selection` mode). Probed both arms (context OFF vs ON)
  through the real `PromptAssembler` / `HTTPLLMClient` / `ValidationGate` against the Qwen3-Coder-30B
  floor + a weak abliterated model, over a public-domain corpus (grounding-lift cases + leak cases).
  **Result:** context lifts grounding **only** on instructions that explicitly demand an external
  fact the model can't already know (OFF 3/18 → ON 15/18 floor); the four *typical* edits
  (grammar / formal / concise / translate) gained **0**, and a fact the model already knows (famous
  name) scored 3/3 *without* context. Leak is **0/12 on both models** — the edit-in-place shape (an
  unambiguous "rewrite THIS" target) resists bleed far better than the dictation shape (~60% naive).
  **But** the shipped context fence ("never output anything from `<context>`") *suppresses* the
  grounding (g6 "state the distance": 0/3 on the obedient strong model vs 2/3 on the weak one) — so
  the feature can't just ride `visible_text` on a selection mode; it needs a different,
  fact-permitting fence. **Verdict:** narrow value (doc-specific reference/fact resolution) + a fence
  conflict → **not built, not queued.** The probe was throwaway and was deleted. A hypothetical future
  opt-in "ground from surrounding text" mode (with a different, fact-permitting fence) is gated on a
  real user actually needing doc-specific fact resolution in edit-in-place — same shape as the OCR
  defer (waiting on a real-world signal, not pending engineering). Do not re-investigate.

## Pick-up state for the next agent (read this first)

- **Committed HEAD = `6028909`** "Wire Whisper engine and dictionary-driven recognition bias across
  all STT engines" — this includes the Whisper engine (WhisperKit 0.9.4), decode-time `biasTerms` for
  Whisper/Apple, the `EngineCapabilities` removal, **and** an early Parakeet CTC bias (since reworked
  — see working tree).
- **Uncommitted working tree** — recognition bias working across all engines + this session's fixes:
  Parakeet **CTC-WS bias** on two tiers (`ParakeetEngine` + `ParakeetModelProfile`, decoder-layers
  crash fix); WhisperKit → **fork of 1.0.0** (`rsperko/argmax-oss-swift` `7cc6ea2`, #372 fix); Apple →
  **`DictationTranscriber`** (only module honoring `contextualStrings`); FluidAudio → **fork**
  (`rsperko/FluidAudio` `b703677`, `enableSpotterRescue` toggle); **Speech Models install flow**
  (`ModelLoadProgress` download progress · `ModelSelfTest` + `ModelSelfTestRunner` post-install smoke
  test over bundled `Resources/model-selftest.wav` · `ModelMaintenance` + `ModelInstallStore.reconcile`
  launch-time marker↔disk reconcile — adopts completed-but-unmarked downloads, deletes orphans), all
  **verified live 2026-06-21**; hotkey-tap re-enable hardening; shared `Log.bias`; doc reconciliation.
  `Package.swift`/`.resolved` pin both forks; `make-app.sh` bundles the self-test clip. Not committed —
  no commits/branches/PRs without explicit user instruction.
- **Build/test:** `swift build` + release bundle clean; `swift test` = **249 tests / 38 suites pass**
  (now incl. `ModelMaintenanceTests` + `ModelSelfTestTests`).
  (The earlier `HistoryController.swift` `Task.detached` sending-closure error is resolved — `HistoryStore`
  is now `Sendable`, which is what the off-main history load needs.)
- **Perf/dead-code review fixes (2026-06-20 GPT review, `agent_notes/gpt_review/`):** (1) **dictation
  cancellation/session ownership** — `DictationController` now retains `dictationTask`, `cancel()`
  cancels it, and `Task.isCancelled` guards after STT + after the rewrite stop a cancelled dictation
  from inserting, writing history, or touching the HUD. Regressed-tested in the new `Tests/KeyScribeTests`
  (gated mock STT, verified red→green). (2) **history load off the main actor** (`HistoryController`)
  + cached `DateFormatter`. (3) **`AudioCapture.start` cleans up on `engine.start()` throw** + builds
  the file before locking. (4) dead members removed (`AudioCapture.isRunning`,
  `Parakeet/WhisperEngine.isLoaded`). (5) **`ContextBudget` budget-policy scaffolding deleted** — see
  "What actually remains" for the queued feature it belonged to. The lower-priority perf items are a
  profiling-gated TODO above.
- **All four models run live (2026-06-21):** both Parakeet tiers, Whisper, Apple — transcription +
  recognition bias verified. The Speech Models **install flow is now verified live too (2026-06-21)** —
  download-with-progress, post-install self-test, select, and delete-with-confirmation; launch-time
  reconcile confirmed against real disk (marker↔dirs, orphan cleanup, download lands in KeyScribe's
  `models/` not FluidAudio's default dir).
- **Parakeet bias decision — RESOLVED:** done via FluidAudio CTC-WS, not the once-planned sherpa-onnx
  migration (that spike in `spikes/` is reference only now).
- **Token-sentinel survival — RESOLVED (2026-06-21), `⟦SN:…⟧` kept.** The redaction wedge's load-bearing
  assumption (a nonce token survives the LLM rewrite verbatim) was only ever verified against the local
  oMLX proxy; now probed live against the **Gemini 2.5 Flash floor** through the real production path
  (`PromptAssembler` → `HTTPLLMClient` → `ValidationGate`). **Table A (production path): 24/24** across 8
  rewrite shapes incl. translate-to-Spanish, summarize, multi-token, adjacent, boundaries, verbatim
  edit-in-place — at temp 0.2 (sampling, not just greedy). **Table B (bake-off, sentinel = only
  variable): all four candidates 24/24** (`⟦SN⟧` / ASCII `[[ ]]` / `{{ }}` / PUA) — characters aren't
  the differentiator on a modern model, so the pick turns on stray/collision risk in prose: `⟦`/`⟧`
  (U+27E6/27E7) never appear in normal text, ASCII brackets/braces collide with code & templating, PUA
  is invisible/fragile → keep `⟦SN:…⟧`. Harness: opt-in `Tests/KeyScribeTests/SentinelSurvivalProbeTests`,
  key from env, never stored (`RUN_SENTINEL_PROBE=1 GEMINI_API_KEY=… [SENTINEL_BAKEOFF=1] swift test
  --filter sentinelSurvival`). The probe is provider-pluggable (`PROBE_PROVIDER`/`PROBE_BASE_URL`/
  `PROBE_MODEL`/`PROBE_API_KEY`) so it can also point at a local oMLX model.
  - **Below-the-floor stress (local oMLX, 2026-06-21) — the gate is the real protection, not the glyph.**
    Ran the same probe down-spectrum. Production path (current sentinel): **Gemini 2.5 Flash 24/24** →
    **Qwen2.5-7B-abliterated 21/24** → **Rocinante-X-12B (roleplay finetune) 6/24**. Every single
    sub-floor failure was caught by `ValidationGate` as `missingToken` — i.e. in production it falls
    back to the local un-rewritten text, so **the protected span never leaks even on a model that
    ignores the preservation rule**; you only lose the rewrite (design.md §4.2 working as designed).
    The weak-model failure mode is the model *interpreting* the placeholder (Rocinante rewrote
    `⟦SN:REDACT:1⟧` → literal `[REDACTED]` or dropped it; both stripped brackets / "fixed" casing —
    `Redact:1`, `REDAct` — when told to capitalize/clean up). **No sentinel rescues a dumb model:**
    handlebar `{{ }}` won on Rocinante (15/24) but *lost* on Qwen (ASCII letters case-mangled to
    `REDAct`), while `⟦SN:…⟧`'s distinctive brackets make models treat it as an opaque copy-blob —
    consistently strong, never worst. Reinforces keeping `⟦SN:…⟧` **and** that a roleplay/abliterated
    model is a poor rewrite-connection choice (a future BYOK-UX / self-test hint, not built).
> **Upstream-PR TODOs — DEFERRED to distant future (2026-06-21 decision).** The three fork pins below
> (WhisperKit, FluidAudio, speech-swift) all work live and are pinned in `Package.swift`/`.resolved`, so
> they cost nothing day-to-day. Filing the upstream PRs to *drop* the pins is explicitly **not** near-term
> work — revisit only when convenient. Kept recorded so the path is known, not because it's queued.

- **TODO (distant future) — file the WhisperKit upstream PR.** Whisper prompt-bias was empty-output-broken in stock
  WhisperKit (decode loop completed mid-prefill on a predicted `<|endoftext|>`, issue #372). Fixed in
  our fork `rsperko/argmax-oss-swift` (branch `keyscribe-prefill-completion-fix`, commit `7cc6ea2`,
  `!isPrefill` guard on the segment-completion check); `Package.swift` is pinned to that revision and
  bias is verified working live (2026-06-21). The fix branch is pushed but **no PR opened upstream
  yet** — open one against `argmaxinc/argmax-oss-swift` so we can eventually drop the fork pin and
  return to a tagged release.
- **TODO (distant future) — file the FluidAudio upstream PR.** The Parakeet 110M (`ctc110m`) over-triggered bias: a
  false "I'm"→"KeyScribe" swap from FluidAudio's spotter-anchored rescue pass (acoustic-only, bypasses
  the similarity gate — unreliable with the weaker CTC head). Fixed in our fork `rsperko/FluidAudio`
  (branch `keyscribe-spotter-rescue-toggle`, commit `b703677`) by adding an `enableSpotterRescue`
  param to `ctcTokenRescore`; `ParakeetEngine` passes `false` for the 110M, `true` for v3.
  `Package.swift` is pinned to that revision; verified live 2026-06-21 (110M now `replacements=2`, no
  false positive). Branch pushed, **no PR opened upstream yet** — open one against
  `FluidInference/FluidAudio` to eventually drop the fork pin.
- **Parakeet bias perf — MEASURED (`BiasBenchmarkTests`, opt-in `RUN_BIAS_BENCH=1`).** On a 36s
  passage, warm per-dictation: **v3 plain 190ms → bias 1541ms** (+1351); **110M plain 138ms → bias
  1066ms** (+929). Whisper 2822ms (bias), Apple 1172ms (bias, ~free). Bias-path breakdown (v3 / 110M):
  resample ~1 · TDT ~190/137 · **makeVocabulary ~25** · **CTC spot pass ~1127/690** · rescorer.create
  ~2 · rescore ~210. Conclusions:
  1. **Vocab+rescorer caching — NOT worth it (dropped).** The cacheable parts total ~27ms (<2% of the
     bias path); `create`'s disk tokenizer load is 2ms (tiny/OS-cached). Content-addressed caching was
     a clean design but solves a 2% problem; skip it (`principles.md` simplicity-first).
  2. **110M encoder-sharing — real redundancy, but NOT fixable in our adapter (needs FluidAudio).**
     Investigated the FluidAudio source: the `CtcKeywordSpotter` runs its **own** mel + `AudioEncoder`
     (`CtcModels`, the `parakeet-ctc-110m-coreml` bundle) over raw audio — a full second encoder pass,
     independent of the TDT encoder. So the redundancy is real and accounts for most of the ~690ms.
     **The building blocks for sharing exist but are dormant in 0.15.4:** the hybrid TDT side loads a
     `ctcHead: MLModel?` ("encoder features → CTC logits"), `AsrManager` already computes the shared
     `encoderOutput` internally, and `spotKeywordsFromLogProbs(logProbs:)` exists to consume
     externally-produced logProbs ("e.g. from a unified Preprocessor"). **But** `ctcHead` is loaded and
     **never run** (no consumer), and neither `encoderOutput` nor CTC logProbs are exposed on
     `ASRResult` or any public API — so we can't wire it from the adapter. Fix path: FluidAudio runs
     `ctcHead` on `encoderOutput` during transcribe and exposes the CTC logProbs; our adapter then calls
     `spotKeywordsFromLogProbs` and skips the separate CTC encoder. **Best upstreamed** (it's clearly
     where FluidAudio is heading) rather than a complex local fork; would cut the ~690ms toward the
     ctcHead matmul (~tens of ms) — **110M only** (v3 is pure TDT + separate `ctc06b`, nothing to
     share). Not urgent (see latency note below).
  Note: absolute latency is fine for *typical short* dictations (CTC pass scales with audio length —
  ~100ms for a 3s clip); the 36s passage is a stress case. Caching/encoder-sharing are not urgent.
- **Profiling-gated perf cleanups — MEASURED, none worth fixing now (2026-06-21).** From the
  2026-06-20 GPT perf/dead-code review. Rather than an Instruments trace (which would bury these
  sub-ms paths inside the multi-hundred-ms STT+LLM dictation and hide the *scaling*), wrote a
  deterministic scaling benchmark — opt-in `Tests/KeyScribeKitTests/PerfBenchmarkTests` (`RUN_PERF_BENCH=1
  swift test -c release --filter perfBenchmark`). Release figures:
  1. **Token processing O(tokens × len)** (`Tokenizer.restore`, `ValidationGate.check`) — **real and
     confirmed**, but fine at realistic sizes: spoken dictation (200 chars/1 token) **33µs**; a 2k-char
     edit (5 tokens) **0.65ms**; a large 10k-char edit (20 tokens) **10ms**. Only the unrealistic
     stress cases hurt (50k×100 = 237ms, 50k×500 = 1.4s). **Tried the obvious gate fix** (replace
     `components(separatedBy:)`'s allocating split with a non-allocating `range(of:)` count) — **no
     measurable change** (154→150ms, within noise): the cost is intrinsic Unicode string-scanning, not
     the allocation. Reverted (churn unearned). A genuine fix needs a single-pass tokenizer-aware
     scanner for both gate and restore — real complexity, not justified by any realistic operating
     point. Security-sensitive; leave exact. **Revisit only if huge-selection edit-in-place becomes real.**
  2. **`HistoryStore.todayString` DateFormatter per append** — fresh **36.6µs/call** vs reused
     0.5µs/call, **once per dictation**. 36µs against a multi-hundred-ms dictation = imperceptible.
     **Don't fix** (trivial+harmless if ever already in that file, but not worth a change).
  3. **`RegexCache` recompiles invalid patterns** — valid (cache hit) ~0µs; invalid recompile
     **1.8µs/call**, at most once per dictation for a persistently-invalid user rule. **Don't fix.**
  4. **Hotkey O(binding count) per key event** (`HotkeyMonitor.handle`) — not benchmarked (fileprivate;
     would need event synthesis). Per event = 1–4 bindings × a flag-mask compare + gesture step (a
     handful of int ops). Idle-typing CPU impact is unmeasurable. **Don't fix** unless idle CPU is ever
     observed high.
  Net: all four are real but irrelevant at realistic operating points. Benchmark is kept (opt-in) so a
  future large-selection use case can re-measure #1/#2 before any fix lands.

---

## Build & test state

- `swift build` — **clean build from scratch passes.**
- `swift test` — **all suites pass.**
- App bundle: `./make-app.sh && open ./KeyScribe.app` (auto-signs with "SnagShot Dev").

---

## M2 — Engine choice + model management (done)

**Fully implemented + unit-tested (high confidence):**
- `SpeechModelCatalog` — curated 3-engine list (parakeet / whisper / apple) with metadata
  (one source of truth). (An earlier per-engine `EngineCapabilities` seam was added here then
  removed — see "Recognition bias" and "Kept-with-rationale".)
- `SpeechModelSet` — selection + deletion rules (exactly-one-active; can't delete the
  system-managed Apple floor; confirm-active / confirm-leaves-no-engine; reassign on delete).
- `EvictionPolicy` — Fastest / Balanced(idle) / Frugal pure decisions; wired into the dictation
  loop and a General ▸ Advanced control.

**Implemented + now run live (2026-06-21):**
- `AppleEngine` (`Sources/KeyScribe/Adapters/AppleEngine.swift`) — native macOS 26 `SpeechAnalyzer`
  /`DictationTranscriber`/`AssetInventory`, batch file transcription. **Run live 2026-06-21**
  (transcription + bias). Note: uses `DictationTranscriber`, **not** `SpeechTranscriber` — the latter
  silently ignores `contextualStrings`, so bias appeared applied but had no effect.
- `ModelManager` flow — `SpeechModelsModel` + `ModelInstallStore` (install marker file under
  `models/`, download via the engine's progress handler, delete with best-effort file removal).
  **Hardened + verified live 2026-06-21:** `ModelInstallStore.reconcile()` runs at launch over
  `ModelMaintenance.reconcile` (adopts completed-but-unmarked downloads, deletes orphan dirs); a
  post-install **self-test** (`ModelSelfTestRunner` → `ModelSelfTest`) transcribes the bundled
  `Resources/model-selftest.wav` and checks distinctive words; `ModelLoadProgress` carries phase +
  fraction to the download UI.
- Speech Models settings UI — engine cards (select / download-with-progress / delete +
  confirmation dialog) + `TabView` (General | Speech Models). **Verified live 2026-06-21.**

**Verified live (2026-06-21):**
1. Settings ▸ Speech Models renders 4 cards (two Parakeet tiers, Whisper, Apple); active engine badged.
2. Download all three downloadable engines with live progress; files land in KeyScribe's `models/`
   (confirmed by timestamp — not FluidAudio's default dir); post-install self-test reports pass.
3. Select / dictate, and delete-with-confirmation (deleted all three; files removed + marker emptied,
   then re-downloaded clean). Apple is the non-deletable system floor.
4. Launch reconcile confirmed idempotent against real disk (marker↔dirs match; orphan dir removed).

> **Observability gap — CLOSED (2026-06-21):** the reconcile / self-test / install / download paths
> now log via `Log.models` (`ModelInstallStore` reconcile + marker mutations, `ModelSelfTestRunner`
> pass/fail/skip incl. the previously-swallowed error, `SpeechModelsModel` download start/complete/fail);
> `Log.insertion` records the AX-insert-vs-paste path. (Note: `log show`/`log stream` did not surface
> the app's os_log on the test machine — a clipboard-marker probe was the reliable ground truth.)

---

## Decisions made autonomously (flag if you disagree)

- **Catalog id == engine id == settings `stt.engine`** ("parakeet"/"whisper"/"apple") — keeps the
  provider, catalog, and settings aligned with no mapping layer.
- **Apple is the system-managed floor** — always "usable", never deletable, so deletion can never
  strand the app without an engine. (The `confirmLeavesNoUsableEngine` rule stays for generality.)
- **Apple asset download is lazy** (on first transcribe), not surfaced as a download button, since
  it's system-managed. First Apple dictation may block while assets install — acceptable for M2,
  worth a HUD note later.
- **Capability flags centralized in the catalog** *(later reversed)* — the `EngineCapabilities`
  seam was set everywhere but read nowhere, so it was removed; engines take `biasTerms` directly via
  `transcribe(wavURL:biasTerms:)` and each biases via its own mechanism (Whisper prompt, Apple
  contextual strings, Parakeet CTC-WS). See "Recognition bias".

## Whisper SDK — DECIDED + WIRED + RUN LIVE (on a patched fork)

Resolved the M2 open question, then upgraded off the dead branch (2026-06-21). **Now pinned to our
fork `rsperko/argmax-oss-swift` `revision: "7cc6ea2"`** (based on upstream **v1.0.0**, the
`argmax-oss-swift` monorepo). The earlier 0.9.4 pin was abandoned: it's pre-monorepo and gets no
fixes. The old "1.0.0 drags in Vapor + swift-openapi" worry was **wrong** — in 1.0.0 those are gated
behind the SDK's `BUILD_ALL` env flag and stay out of resolution when you depend on just the
`WhisperKit` product. Verified clean: transitive deps are vendored `swift-transformers` +
`swift-argument-parser` (CLI-only), **no Vapor**. Why a fork rather than the stock tag — see
"Recognition bias" (the #372 empty-output fix); the upstream PR is a tracked TODO above.

`WhisperEngine` (`Sources/KeyScribe/Adapters/WhisperEngine.swift`) downloads the turbo variant
`openai_whisper-large-v3-v20240930_turbo_632MB` into `models/whisper/` via `WhisperKit.download`
(progress forwarded to the Speech Models download UI), loads with download disabled, and
transcribes via `pipe.transcribe(audioPath:)`. It's a `final class … @unchecked Sendable` with
`nonisolated(unsafe)` pipe storage — the WhisperKit class still isn't `Sendable` (even in 1.0.0's
Swift 6 concurrency), so an actor can't await its methods; access is serialized by the
commit-on-release dictation loop. The AppDelegate download closure handles the `whisper` id;
`ModelInstallStore` maps it to the `models/whisper` subdir for deletion; catalog download size ~632MB.

**Run live and verified (2026-06-21):** model loads into the ANE (~1.1s), transcribes real mic audio,
and recognition bias works (see "Recognition bias"). The download/select/dictate/delete UI flow has
now had its full pass too (verified live 2026-06-21 — see "M2" above).

---

## Recognition bias — all three engines, run live (interactively verified)

The Dictionary feeds each engine's recognition bias at STT. `SpeechEngine.transcribe` has
a `biasTerms: [String]` param; `DictationController.recognitionBiasTerms()` supplies global ⊕
Phase-A mode dictionary (a Phase-B voice route resolves post-STT, so it can't bias — design.md §4.3).
- **Whisper** (`WhisperEngine`): dictionary terms tokenized via the WhisperKit tokenizer and passed
  as `DecodingOptions.promptTokens` (word tokens only) — the `<|startofprev|>` conditioning prompt.
  **Requires our WhisperKit fork:** stock 1.0.0 returns an *empty* transcript whenever `promptTokens`
  are set (issue #372 — the decode loop completed mid-prefill on a predicted `<|endoftext|>`; our
  `!isPrefill` guard on the completion check fixes it; PR #438's `firstTokenLogProbThreshold` is a
  different branch and does **not** fix this). Verified live 2026-06-21: bias is a **soft hint** — a
  distinctive coinage like "KeyScribe" flips from a near-miss mishearing → "KeyScribe", but it won't override a strong
  acoustic match to common words ("FluidBloo" stayed "Fluid Blue"). Consistent with §4.2: only nonce
  tokens are guaranteed to survive; the dictionary is a hint.
- **Apple** (`AppleEngine`): terms set as `AnalysisContext.contextualStrings[.general]` via
  `analyzer.setContext` before `start`. **Requires `DictationTranscriber`** — `SpeechTranscriber`
  silently ignores `contextualStrings` (confirmed on Apple dev forums), so bias logged `applied=true`
  with zero effect until the module swap. Verified live 2026-06-21: strongest of the three — both
  "KeyScribe" and "FluidBloo" landed (a real contextual-biasing API, not a soft hint).
- **Parakeet** (`ParakeetEngine`): **FluidAudio CTC-WS** (NeMo constrained-CTC keyword spotting), two
  tiers. TDT transcribes (with token timings); a same-tier CTC model re-scores dictionary terms
  against the acoustic frames; a word swaps only when CTC evidence **and** string similarity clear
  confidence thresholds — decode-adjacent and confidence-gated, **not** the old blind span
  substitution. Per-tier config in `ParakeetModelProfile` (v3 ↔ ctc06b; TDT-CTC 110M ↔ ctc110m).
  Verified live 2026-06-21: both tiers bias correctly. Cost: it runs a **second acoustic pass** (the
  only engine that does) — Whisper/Apple bias single-pass.

**Two bugs fixed to get Parakeet bias working (2026-06-21):**
1. **110M crash** — `TdtDecoderState()` defaulted to 2 decoder layers; `tdtCtc110m` has 1, so CoreML
   threw a `(2 vs 1)` shape mismatch. Fixed by sizing the state with `version.decoderLayers`.
2. **110M over-trigger** — FluidAudio's spotter-anchored *rescue pass* (acoustic-only, bypasses the
   similarity gate; meant to catch badly-mangled brand names) false-fired on the weaker ctc110m
   ("I'm"→"KeyScribe"). Fixed via our **FluidAudio fork** (`rsperko/FluidAudio` `b703677`, adds
   `enableSpotterRescue`): off for the 110M, on for v3. `ParakeetModelProfile.spotterRescue` carries
   the per-tier choice. Upstream PR is a tracked TODO.

**History — the blind rescorer (removed) and the abandoned sherpa plan.** Earlier this session
FluidAudio's *post-STT* CTC rescorer (blind find-and-replace) corrupted output (`Yeah`→`Bayes`,
`Open`→`Eigen`) and was removed; the plan was to migrate to **sherpa-onnx** decode-time hotwords
(spike in `spikes/sherpa-bias/`: FP-safe, but ONNX **CPU-only** — no ANE offload, ~1.3–1.9
CPU-core-sec for a 26 s clip). That migration is **no longer needed**: FluidAudio's *other* vocab
feature — the confidence-gated **CTC-WS** keyword spotter (distinct from the blind rescorer) — does the
job on-device on the ANE. The sherpa spike is kept as reference only.

---

## M3 — pipeline framework (mostly done)

**Fully implemented + unit-tested, and wired into the live dictation flow:**
- `Pipeline` / `PipelineStage` / `StagePosition` — command-pattern stages with canonical ordering
  (live edits → replacements → … tokenize/restore positions reserved for M6).
- `ReplacementsStage` — literal (case-insensitive) + regex with capture substitution; invalid
  regex skipped.
- `LiveEditsStage` — new line, new paragraph, scratch that (sentence/newline aware).
- `VocabularyConfig` — `DictionarySet` / `ReplacementsSet` TOML models + global↔local merge.
- `DictationController.processTranscript` runs `Pipeline([LiveEdits, Replacements(global)])` on
  every transcript before insertion. **Reloads `replacements.toml` each dictation** so hand-edits
  apply immediately. (Per-mode opt-in + mode-local vocab arrive with M4.)

**Verify on return (interactive):** edit `~/Library/Application Support/KeyScribe/replacements.toml`
(add a `[[rules]]` heard→replace), dictate the phrase, confirm substitution; say "… new line …"
and "… scratch that …" and confirm structural edits.

**UI status:**
- Global Dictionary / Replacements settings UI — **built** (the **Vocabulary** pane; see "Settings
  UI — built").
- Minimal correction panel (global shortcut, Heard pre-filled from selection) — **still deferred**. The
  History detail's Add to Dictionary / Create Replacement is the current correction surface (M7).
Dictionary recognition effect uses per-engine bias (Whisper prompt, Apple contextual strings,
Parakeet CTC-WS — see "Recognition bias" above) + the M5 LLM hint.

---

## M4 — Modes (done)

**Fully implemented + unit-tested:** `Mode` TOML model (full schema, defaults, round-trip),
`ModeResolver` (Phase A app/URL context eligibility + Phase B trigger-phrase suffix routing/strip),
`MigrationRunner` (shared forward-only, backup-first), `ModeStore.starterModes/loadAll/seedStartersIfEmpty`.

**Wired into the app:** first launch **seeds 3 starter modes** into `~/Library/Application
Support/KeyScribe/modes/`; each dictation resolves the mode from the frontmost app (Phase A, shown
in the HUD), runs that mode's pipeline (live-edits opt-in + mode-local⊕global replacements), and a
spoken trigger-phrase suffix re-routes + strips (Phase B).

**Verify on return (interactive):** dictate in different apps and confirm the HUD mode name +
behavior change per the seeded modes / a mode you constrain to an app; end a sentence with a
mode's trigger phrase and confirm re-route + suffix strip.

**Resolver semantics (design.md §4.3) — now implemented in `ModeResolver`:** there is no separate
"global hotkey" (the default mode owns Fn/Globe); an explicit key **forces** its mode overriding
context; both phases resolve by **specificity → declaration order** over the context-eligible set;
only constrained modes auto-start (unconstrained non-defaults are key/voice-only). Phase-B voice
routing adopts only the post-STT pipeline. Tested in `ModeResolverTests`.

**Mode-editor UI — built (was deferred):** the **Modes** pane (`ModesSettingsView`) is a full
master-detail editor (create / edit / enable / delete). It now sets per-mode **insertion method**,
**exclude-from-history**, and the **visible_text** context toggle (all three already applied at
runtime). See "Settings UI — built".

Per-mode **physical trigger keys** are **done** (commit `925cbea`, verified live): `buildHotkeyMonitor`
registers one `HotkeyMonitor.Binding` per enabled mode's `triggerKeys`; the monitor dispatches each
binding's `triggerKey`, which `resolvePhaseA` uses to force that mode over context. See "Verified live".

**URL context — wired and verified live (2026-06-21):** a `github\.com` `url_pattern` mode resolved
(HUD named it) only on github.com and the default elsewhere, over the Automation grant — confirming
both the AppleScript URL fetch and the regex routing.
`ContextProbe.browserURL(forBundleId:)` reads the active tab via AppleScript/Apple Events, never AX.
**No hardcoded browser list:** "is it a browser" comes from Launch Services
(`NSWorkspace.urlsForApplications(toOpen: https)` — any app that handles https), and the URL itself
is read by trying both AppleScript dialects (WebKit `URL of front document`, Chromium `URL of active
tab of front window`) against the same app — exactly one succeeds. Fed into `RoutingContext.url` in
`DictationController.resolveMode`, but
**only when `ModeResolver.requiresURLContext(modes)` is true** — i.e. some enabled mode has a
`url_pattern` — so the Automation prompt never fires for users who don't route by site. A
non-browser frontmost app sends no Apple event. `NSAppleEventsUsageDescription` added to the
bundle's Info.plist (`make-app.sh`); the hardened-runtime `com.apple.security.automation.apple-events`
entitlement remains an M7/notarization need (not blocking the dev-signed build).

---

## Verified live this interactive session

The full M1–M6 pipeline runs end-to-end in the real app:
- **Dictation** (Fn → speak → insert), **modes** (HUD mode name, Phase-A app routing, Phase-B
  trigger-phrase routing), **replacements** + **live edits**.
- **BYOK rewrite (M5)** — a "polish that" mode rewrote text via local **oMLX**, key fetched from
  **Keychain** through `HTTPLLMClient`. Model is one line in `connections.toml` (Qwen3-Coder-30B).
- **Redaction wedge (M6)** — dictated an email in a privacy mode; a proof log confirmed the outbound
  payload carried `⟦SN:REDACT:1⟧` (never the email), and the insert restored it locally.
- **Edit-in-place** — select text, hold **right-Option**, speak an instruction → selection replaced;
  **non-destructive on every failure** (selection left untouched).
- **Per-mode trigger keys** — multi-binding hotkey monitor, exact chord matching.

## Built / fixed this interactive session (beyond the milestone checklists)

- `HTTPLLMClient` + `KeychainStore`; rewrite + tokenize/restore wired into `DictationController`;
  HUD `.rewriting` ("Best-effort redaction") state.
- Edit-in-place (selection capture, abort-on-failure), per-mode keys, **exact chord matching**.
- `ConfigCache` + `ConfigWatcher` (FSEvents) + Settings **Reload Configuration** button — config is
  loaded once and cached; zero per-dictation config I/O.
- `RegexCache` — regex patterns compiled once, not per dictation.
- Bug fixes: first-run hotkey activation, onboarding-skip when permissions granted, trigger-phrase
  trailing-punctuation, model-path (FluidAudio `to:` → `models/`), logging hygiene.
- DRY/dead-code/test pass: `ConfigDecode` helper, removed dead inserter paths.
- Dictionary LLM-hint + shared fragments + app context wired into the rewrite prompt.

## M7 — local history (built; UI needs interactive verification)

- **Pure + tested:** `HistoryEntry` + JSONL codec (multi-line transcripts stay one line),
  `HistoryRetention` (drop day-files older than `retention_days`), `HistorySearch`, `HistoryStore`
  (append-only `history/<day>.jsonl`, newest-first read, retention delete). Correction surface:
  `DictionarySet.adding(word:)` / `ReplacementsSet.addingLiteral(heard:replace:)` (dedup-aware) +
  store `write`.
- **Wired:** `DictationController` records one entry per text-producing dictation (skips noSpeech;
  honors `[history] enabled` + per-mode `exclude_from_history`); stores heard / result / outcome /
  cloud+redaction+context metadata / connection+model / **exact prompt with tokens** — never audio,
  never the redaction map. Retention runs at launch.
- **Built, unverified (SwiftUI):** History window (menu **History…**) — grouped/searchable list,
  Heard→Result detail, processing-details disclosure, **Add to Dictionary** / **Create Replacement**,
  storage-truth footer. Needs a live click-through.

## What actually remains

- **M7 polish:** History window live verification; **distribution** (notarized Developer ID +
  Sparkle in-app updates + menu-bar update indicator); progressive-disclosure + accessibility pass.
  (Open-source hygiene — GPLv3 `LICENSE`, `THIRD-PARTY-NOTICES.md`, expanded notices screen — **done
  2026-06-21**.)
- **BYOK Keychain → data-protection keychain (gated on the Developer ID Team ID, do it *with* M7
  notarization):** `KeychainStore` uses the **legacy file-based keychain**, where reads are gated by
  per-item ACLs + a partition list matched against the app's Designated Requirement. End users on a
  notarized Developer ID build won't normally be prompted (the app owns its items, stable DR), but any
  signing-identity / App-ID-prefix change re-prompts the whole install base — a known footgun. The
  robust fix (Apple TN3137: "use the data-protection keychain for all new code") is to add
  `kSecUseDataProtectionKeychain: true` to every `KeychainStore` query **plus** a `keychain-access-groups`
  entitlement (`$(AppIdentifierPrefix)com.keyscribe.app`). That removes the prompt class entirely (access
  governed by entitlement/Team ID, not ACLs). **Hard constraint:** the data-protection keychain returns
  `errSecMissingEntitlement` (-34018) without a real App ID, so this **cannot** ship on the current
  self-signed `SnagShot Dev` build — it requires the Developer ID Team ID, which is why it's bundled
  with notarization. No shipped users yet ⇒ adopt it from the start, no legacy→DP migration needed.
  (Footgun seen 2026-06-21: seeding a connection's key with the `security` CLI instead of through the
  app's Save-Key field gives the item an `apple:`-only partition list, so the app is prompted on every
  read — always let the app create its own Keychain items.)
- **Settings UIs — built (2026-06-21):** Mode editor (**Modes**), BYOK connections (**AI Services**),
  and global Dictionary/Replacements (**Vocabulary**) all ship, plus a **Permissions** pane and an
  **Advanced** pane — a 7-pane Settings window (see "Settings UI — built"). The **standalone correction
  panel** (global shortcut) is the only deferred UI left; History's Add to Dictionary / Create
  Replacement covers correction for now. Two Settings-editor follow-ups remain (per-keystroke writes →
  explicit Save; default-mode deletion guard — see "Settings-editor follow-ups").
- **Engines:** all four models (both Parakeet tiers, Whisper, Apple) **run live with bias working**
  (2026-06-21), and the Speech Models **install/download/select/delete UI flow is now verified live**
  too (2026-06-21). Whisper on our WhisperKit-1.0.0 fork; Parakeet bias via FluidAudio CTC-WS (fork);
  Apple via `DictationTranscriber`. See "Recognition bias" and "Whisper SDK …" above.
- **M5 leftovers:** ~~token-sentinel survival probe (real Gemini)~~ **done 2026-06-21** — see below;
  best-of-breed connection-UX research still open.
- **Visible-text context — BUILT + live-verified (2026-06-21).** See the "Visible-text context"
  section below for the full arc (spike → adapter → budget → measured fence). App context is wired;
  URL context wired and **live-verified (2026-06-21)**. OCR fallback for canvas/sparse-AX apps stays a later option.
- **Per-mode insertion method — done** (all 3 methods wired + live-verified 2026-06-21; AX false-success
  data-loss bug fixed); set per mode in Modes ▸ *Result handling* (see "Settings UI — built").

## Settings-editor follow-ups (captured 2026-06-21, not yet built)

The new Settings panes (Modes, AI Services, Vocabulary) ship working, but two known
items are deferred:

- **Per-keystroke disk writes → move to explicit Save.** Every field edit in the Mode,
  AI-service, and Replacements editors writes its TOML on each character (binding setter →
  `*Store.write`). Risks: a crash mid-edit persists a half-typed value; each write trips the
  `supportDir` FSEvents watcher → `reloadConfig()` (cache invalidate + hotkey rebind + status
  refresh), so the user churns the config + event tap while typing; and there is no cancel/discard.
  **Plan:** the detail editor edits a local `@State` draft (`Mode`/`Connection`) seeded from the
  selected item (reset on selection change via `.id(item.id)`); a footer offers **Save** (enabled
  when the draft differs and validates) and **Revert**. `create()`/`delete()` stay immediate so the
  item exists to select; only field edits move behind Save. Dictionary/Replacements add+remove are
  already discrete and can stay immediate — only the inline rule TextFields need draft+Save (or
  commit on focus-loss/`onSubmit`). Independently, coalesce the watcher echo so a self-induced write
  does not rebind the hotkey tap. **Open decision:** per-item Save in the detail (recommended,
  matches master/detail) vs one Save bar for the whole pane.

- **Deleting the default mode dangles `settings.default_mode_id`.** `ModesSettingsModel.delete`
  does not guard the mode named by `default_mode_id`; runtime falls back to `modes.first`, so no
  crash, but the setting points at nothing. Either reassign `default_mode_id` on delete or block
  deleting the current default.

## Kept-with-rationale (flagged in the DRY/YAGNI pass)

`MigrationRunner` (built + tested but not
wired — no v2 to migrate yet). (`Mode.insertion` was listed here as inert/paste-only; it is now
wired — `TextInserter.perform` dispatches it via the pure `insertionAction`.) (`EngineCapabilities` was removed — it was set everywhere but read
nowhere; engines take `biasTerms` directly via `transcribe(wavURL:biasTerms:)` — Whisper (prompt),
Apple (contextual strings), and Parakeet (CTC-WS) each bias via their own mechanism.)
