# KeyScribe — Agent Orientation

KeyScribe is a **privacy-first, local-first voice dictation app for macOS** (Superwhisper/
MacWhisper class). Speech recognition is **always on-device**; an **optional, user-keyed (BYOK)
LLM rewrite** is the only thing that may ever leave the machine, and only after sensitive spans
are tokenized out. Native Swift/SwiftUI menu-bar app. Open source, GPLv3.

This file is the entry point. Read the design docs before writing code — they are the contract.

---

## Hard invariants (never violate)

- **STT is always on-device. There is no cloud STT, ever.**
- **Exactly one STT engine is active globally** (user-selected). Multiple named *LLMs* are
  allowed; the STT engine is singular. Resolve it through one provider (seam for per-mode later,
  not built — YAGNI).
- **The only outbound network call that carries content is an explicit BYOK LLM rewrite**, over a
  redacted payload. One content-free exception: when the **Phase-A resolved mode is wired to a BYOK
  connection** — and only after the secure-aware snapshot has confirmed the field is not a password
  field — a **bodyless, auth-less HEAD preconnect** to that connection's host may fire during recording
  to warm the TLS connection (`HTTPLLMClient.preconnect`, gated by `DictationController.maybePreconnect`
  on the resolved mode AND the adopted snapshot). It carries no user content and touches only the host
  that mode's connection points at. The rewrite may not ultimately fire (cancel, no speech, a
  whole-utterance replacement, or a Phase-B route to a local mode); the preconnect stays content-free
  regardless, and a focused secure field neuters the mode so none fires there.
- **No telemetry, no analytics.** Speech, transcripts, and usage are never collected.
- **Dictation is batch (commit-on-release) and inserts atomically** — one ⌘Z undoes the whole
  dictation.
- **No app/mode identity in source.** No `if app == "Slack"`, no per-app presets. A Mode is a
  named bag of config a generic pipeline executes (`docs/development/principles.md` §2). Adding a mode = adding
  data, never code.
- **Public docs are for users first.** `README.md`, `FAQ.md`, `PRIVACY.md`, and
  `docs/getting_started.md` should explain outcomes, setup, and tradeoffs in plain language.
  Implementation details, schemas, benchmark methodology, prompt internals, architecture, and
  contributor-only rationale belong under `docs/reference/` or `docs/development/`, with links from
  user docs only when they help an advanced reader continue.
- **Distribution docs are feature-facing.** `agent_notes/distribution_docs/feature-inventory.md`
  is a user-visible feature inventory: keep what users can do, why they care, and relative marketing
  value. Do not turn it into implementation notes, verification details, benchmark harness notes, or
  GIF/storyboard scripts; those belong in development/reference docs or the distribution GIF scripts.

---

## Footguns (read the cited section before touching the area — these silently corrupt or leak)

- **Pipeline order is fixed and load-bearing** (`docs/development/design.md` §4.2.1): **verbatim tokenizes FIRST**
  (before the text stages, so a verbatim span is protected from everything except STT), the text
  stages run, **redaction tokenizes LAST** (just before the LLM), and restore is each command's
  `post` in strict **reverse/LIFO**, on every path (incl. no-LLM). Stages are commands with
  `apply`/`post`; one-way text stages leave `post` a no-op. Wrong order silently corrupts output or
  leaks a redacted span — never improvise it.
- **Tokenization is safety, not cosmetics.** The token→original map is **in-memory only, never
  logged or written to history**, and the **post-LLM validation gate** (every issued `⟦SN:…⟧` that was
  sent to the model returns exactly once; an issued-but-unsent token appearing in the output is stray;
  non-empty) is a hard check, not normalization: a dropped redaction token
  leaks the protected span, a dropped verbatim token corrupts the insert. On failure → one
  stricter retry → else local fallback + HUD notice (`docs/development/design.md` §4.2).
- **Privacy mode and context are mutually exclusive.** When a mode's privacy toggle is on, the
  context checkboxes are **forced off and locked** — the redacted transcript is the only user
  content that may leave the machine (`docs/development/design.md` §4.4).
- **Dictionary is a hint, replacements are not protected.** Dictionary terms only tell the LLM
  "valid, not a misspelling" (it may still transform them); replacements flow into the LLM and
  can be rewritten. Only **nonce tokens** are guaranteed to survive the rewrite (`docs/development/design.md` §4.2).
  **One exception:** a replacement that consumes the **entire** utterance (a "whole-utterance
  replacement" like `slash resume`→`/resume`) is inserted verbatim and **bypasses the LLM, trailing,
  and trim** — detected at `ReplacementsStage` (reported via `PipelineContext.bareReplacement`) and
  short-circuited in `DictationController.produceDictationText`. Regex/literal replacements both match
  **case-insensitively** by default (STT output is engine-cased; `(?-i)` opts back in). See
  `docs/reference/config_schema.md` *Replacement matching & output*.
- **Credential material is never persisted in config.** Saved API keys live in Keychain and TOML
  stores only `key_ref`; command-generated bearer tokens are in-memory only. `token_command` stores
  the command to run, not the token material itself (`docs/reference/config_schema.md`).
- **Edit-in-place is a capability, not a special mode** — any mode can be `source=selection` /
  `output=replace_selection`; ⌘C→pasteboard is the selection capture, AX is a native-only bonus
  (`docs/development/design.md` §4.3).
- **Capture pins the chosen device on a raw AUHAL unit — it NEVER changes the macOS system default
  input.** Device-pinned capture goes through `HALInputUnit` (`kAudioUnitSubType_HALOutput`): set the
  unit's `CurrentDevice`, read the device's **native** `StreamFormat`, then set the client format to
  match it (Float32 non-interleaved at the device's own rate/channels) — matching the client format to
  the device is exactly how the **-10868 (`kAudioUnitErr_FormatNotSupported`)** that plagued the old
  `AVAudioEngine.inputNode` path is avoided, so there is no reason to touch the global default. The prior
  implementation temporarily flipped `kAudioHardwarePropertyDefaultInputDevice` to dodge -10868; that is
  a confirmed antipattern (every reputable recorder pins the device instance-locally; AudioKit shipped
  and then removed a default-flip as a bug) and it caused a user-visible side effect (every dictation
  briefly hijacked the system mic) plus intermittent `preferredInputFailed`. **Do not reintroduce any
  `setSystemDefaultInput` call on the capture path** — that function survives ONLY for the legacy
  crash-reconcile that undoes a default a pre-AUHAL build may have stranded. A **present** preferred
  device that fails to bring up surfaces `preferredInputFailed` (don't silently record from a different
  mic); a default-follow failure retries once after 250 ms, then `formatUnavailable`.
- **Commit-on-release drains the tail before stopping — do not revert to an immediate stop.** The AUHAL
  IO proc delivers a buffer once per hardware period, so at release the in-progress period holding the
  final word is undelivered; tearing the unit down right then clips it. `handleCommit` flips the HUD to
  *transcribing* and then `await`s `AudioCapture.finishDraining()`, which keeps the unit running until a
  delivered buffer's host time (`inTimeStamp.mHostTime`) covers the release instant (`TailDrainGate`,
  with a buffer-count fallback for invalid timestamps and a 300 ms backstop), and only then tears it down
  (`teardownAndFinalize`, which `stop()`s a non-Bluetooth unit but **disposes** a Bluetooth one to free
  HFP, then joins the writer thread and closes the WAV — in that order — so no in-flight write races the
  finalize). **`stop()` is the immediate, audio-discarding teardown** (disposes the unit) — keep it for
  `cancel()`/over-limit abort only; the commit path must use `finishDraining()`. `stop()` also force-resumes
  any pending drain so a direct stop never strands the awaiter. The `wav … drain=Xms` `DictationController` debug log reports
  the actual flush time (≈300 ms means the backstop fired). Don't reorder the HUD flip after the await —
  the drain latency must stay invisible.
- **The realtime IO callback is lock-free / allocation-free / syscall-free — never add file I/O, a lock, a
  `Task`, or a continuation resume to it.** The AUHAL render callback runs on CoreAudio's realtime IO thread;
  anything that can block there (a disk stall, a lock the main actor also holds, a `Task` allocation) overruns
  the device IO cycle → dropped input (audibly missing words) and can glitch the device for other clients. The
  RT handler (`AudioCapture.handle`) does ONLY three bounded things: gate on the `capturing` atomic, copy the
  delivered frames into a preallocated lock-free SPSC ring (`AudioSampleRing`, KeyScribeKit), and publish the
  perceptual level into an atomic (`vDSP_rmsqv`, a Float bit pattern). Everything heavy — resampling
  (`AVAudioConverter`), the `AVAudioFile` write, and feeding the `TailDrainGate` — runs on a dedicated writer
  thread (`CaptureWriter`) that polls the ring off-RT (5 ms tick, no wakeup is EVER signalled from the RT
  thread). The HUD meter is **pulled** at ~30 Hz (`DictationController` polls `AudioCapture.currentLevel`), not
  pushed per buffer — there is no per-buffer main-actor hop. The ring is owned by `AudioCapture` and reset (or,
  when the bound device's IO period changed, REALLOCATED) per capture in the quiescent arm window — `armSync`
  sizes `slotCount` to target ~30 ms of headroom for the device's actual period (`AudioSampleRing.geometry`,
  clamped to ≤64 slots but always above one writer poll tick), so a small pro-interface buffer can't starve the
  ring below a poll tick. **The arm order is load-bearing for this: `armSync` CONFIGURES the unit first
  (`configureCaptureDevice` — bind + initialize, including the default-follow retry, but the IOProc is NOT
  started), so the device that will actually deliver is known BEFORE the ring is sized; then it sizes the ring
  for that bound device, starts the writer (BEFORE publishing the session/`lastWriter`, so no teardown path can
  observe a published-but-not-yet-started writer and skip joining its thread), sets `capturing=true`, and calls
  `startConfiguredUnit` LAST — so the first delivered buffer already lands in a correctly-sized ring with no head
  clip, and a retry that rebinds a different device cannot leave the ring mis-sized.** The swapped-in ring is published to the RT thread by the
  same `capturing.store(true, .releasing)` the callback's acquire load pairs with, and is NEVER reassigned while
  `capturing` is true (the mid-recording restart keeps its ring — the one remaining case where the ring can
  outlast a device change, bounded by the drain backstop). The previous capture's writer is JOINED
  (`CaptureWriter.finish`, multi-waiter via a `DispatchGroup`) before the next arm resets/replaces the ring, so
  a cancel's async teardown can never race a still-draining consumer. On
  commit, `finishDraining` awaits the writer join before returning the URL, and the writer drops its `AVAudioFile`
  reference on exit so the session's is the last one — the WAV is finalized/closed before transcription reads it.
  Teardown ordering is load-bearing: `capturing` → false (RT stops pushing, which SEVERS RT→ring→writer→file),
  `writer.finish` (drains remaining + flushes the resampler tail + joins), release the file (WAV closed —
  before the unit stop, so a wedged unit stop can't return an open file to transcription), then stop/dispose
  the unit. Because a capture defect here is INAUDIBLE (audio goes straight to STT), validate with
  **`KeyScribe --capture-probe`** (drives the real capture path over a known tone and scores glitches/SINAD),
  the teardown `Log.audio` line `ringDropped=N overloads=M writerDropped=K oversizeDropped=J` (all must be 0 —
  the writer-keep-up, CoreAudio-RT-deadline, downstream WAV-write/converter, and RT IO-period-growth canaries;
  `writerDropped` counts frames the writer accepted off the ring but failed to persist, e.g. a disk-full or
  odd-format-converter failure that is invisible to the ring counters; `oversizeDropped` counts frames the RT
  callback dropped because the device grew its IO period past scratch mid-capture — upstream of the ring, so
  invisible to `ringDropped`, and now watched for recovery via a `BufferFrameSize` restart), and
  `KEYSCRIBE_KEEP_CAPTURE=<dir>` to retain WAVs for offline inspection.
  See `agent_notes/fable_review/audio-capture.md` H4 and the W17 entry in `worklist.md`.
- **HAL unit bring-up/teardown run off the main thread on a serial queue, watchdogged — never move them
  back onto `@MainActor`.** `AudioUnitInitialize`/`AudioOutputUnitStart`/`Stop`/`AudioComponentInstanceDispose`
  can block for a long time (or indefinitely) on a transitioning device — classically a Bluetooth headset
  forced from A2DP into HFP the moment capture opens an input stream — and doing that on the main thread
  froze the whole app *and* (via the event tap) global input. `AudioCapture` confines every `HALInputUnit`
  control call to a private serial `controlQueue`; `start()` is `async` and bounded by a watchdog
  (`runWithBudget`). **`start()` resolves on READINESS — the input's first valid buffer — not on the
  AudioUnit start call returning**: bind/initialize/start can all succeed on a route that never delivers audio,
  so a start return proves nothing. Readiness is observed on the **writer thread**
  (`CaptureWriter.onFirstBuffer` → `SignalLatch`), ABOVE head admission — the proving buffer arrives while
  admission is still closed, so a check below the gate would never see it — and **never signalled from the RT
  callback**. `AudioCapture.awaitReadiness` releases its wait on cancellation (the deadline ABANDONS the
  operation, so an unsignalled latch would strand the continuation) and therefore MUST keep its
  `Task.checkCancellation()`: without it a released wait can return success and beat the timer to
  `runWithBudget`'s one-shot gate, reporting a ready mic that never delivered a buffer. Capture **arms with
  admission CLOSED and records nothing** until `openAdmission(afterHostTime:)` publishes the cue-end boundary
  (0 ⇒ admit from now): the start cue is the go-signal, so it may not sound until the route is proven live,
  and it then plays into an already-open mic that must not record it. Every `AudioCapture.start` caller must
  open admission or it captures silence — `DictationController.beginCapture` and `--capture-probe` are the two.
  **One extensible `ReadinessBudget` bounds the WHOLE operation** — configure, start, and the wait for a
  buffer — since any of them can be the slow step on a transitioning route: `bringUpTimeout` (2 s) **plus**
  `bringUpGrace` (2 s) for local devices, `bluetoothReadyTimeout` (9 s) for Bluetooth, whose A2DP→HFP
  negotiation can outrun the 4 s window and surface as a spurious "Could not start the microphone" (observed
  once as two failures then a success on the third trigger; the exact route state during the failures was
  never established — see `agent_notes/mic_issue`). **The budget must not stay fixed at the initial target**:
  the delivering device can change after it is sized — a failed default bind re-reads the system default, and
  an arming-time restart can rebind (the session is published before readiness, so topology changes act on it).
  `selectRoute` RAISES the budget as each route is CHOSEN — before the configure/start it pays for, since that
  call is itself what blocks, and the latch is one-shot so a budget that already expired cannot be recovered.
  It never lowers. Repeated churn cannot wait forever because the window is measured from ONE origin (the
  timer arming inside `runWithBudget`), not restarted per raise — so the total wait is bounded by the slowest
  transport's value however many times a route is reselected. There is deliberately no separate clamp: with
  only two transports the only reachable values are 4 s and 9 s, and a cap over them would be unreachable
  code. A future transport slower than Bluetooth raises that ceiling by construction — decide then whether an
  absolute cap is wanted, rather than carrying a dead one now.
  Drop the raise and a local target that rebinds onto Bluetooth inherits the 4 s cliff: the
  original bug, one route change removed. Policy label and diagnostics likewise key off ONE `captureTarget()`
  resolution threaded into `armSync` (sampling transport separately from the bind also mislabels a
  disconnected preference as `explicit`). The watchdog is **non-destructive**: it **adopts** a bring-up
  landing anywhere in the window rather than discarding it — a resident unit whose cached binding went stale
  over idle can need ~2 s to re-realize the input unit on the hot path, and a tight 2 s watchdog used to throw
  that late success on the floor. Only after the budget is spent (a genuinely wedged or never-delivering
  device) does it abandon the call on its (now-orphaned) queue and let the next dictation rebuild a fresh unit
  + queue — so the healthy path keeps reusing the prewarmed unit (no fresh build per dictation) and a true
  wedge degrades to a graceful "Could not start the microphone" instead of a hang. Waiting cannot reintroduce
  the freeze — bring-up is off-main, so the main actor only `await`s. (`prewarm` keeps the tight `bringUpTimeout` — it configures/initializes the unit but does
  NOT start the IOProc, so the mic indicator never lights; it is skipped for Bluetooth so idle never forces
  HFP.) A complementary idle/wake **binding refresh** attacks the same staleness proactively:
  `refreshBinding()` rebuilds + re-prewarms the idle unit, driven by `DictationController` on a ~4 min idle
  timer and by an `NSWorkspace.didWakeNotification` observer. **All of this idle mic warm-up is gated on the
  `Eviction` performance tier (`settings.stt.eviction`) via `EvictionPolicy` — the same dial that governs STT
  model residency**: only `.fastest` runs the ~4 min periodic refresh (`periodicallyRefreshesCapture`);
  `.frugal` never prewarms at all (`shouldPrewarmCapture` false → mic opened only on the trigger's `start()`,
  paying the cold realization the grace window absorbs); `.balanced` prewarms around use but drops the periodic
  refresh and disposes the warm unit at the model's idle-eviction checkpoint (`releaseWarm()`, gated by
  `releasesWarmCaptureOnIdle`). This exists because the periodic dispose→re-init cycle is observable to
  mic-usage monitors as a repeated grab/release; Balanced/Frugal exist for coexistence with mic-sensitive apps.
  To diagnose the next occurrence rather than
  infer it, `start()` emits ONE structured record per capture start on the `audio` category
  (`CaptureStartRecord`; `Log.audio`, `.debug`, `.error` on a terminal failure): `capture-start
  outcome=ready|never-ready|cancelled|failed policy=explicit|default transport=bluetooth|other
  bound-transport=… target=… bound=… configure=…ms start-returned=…ms first-buffer=…ms events=[…]`. A healthy
  prewarmed start is a few ms to first buffer; the gap between `start-returned` and `first-buffer` is the
  route actually opening. **Group by the transport that DELIVERED — `bound-transport` when present, else
  `transport`**: they differ when a rebind moved the route, and grouping on `transport` alone files a capture
  that delivered over Bluetooth under `other`. `bound`/`bound-transport` are frozen at the first buffer on a
  `ready` outcome, so a restart landing just after readiness cannot re-file that timing under a device which
  never delivered it. Timings are from `start()`, **not** from the trigger (the press pays the synchronous
  secure-field probe and mode resolution first) — trigger-to-recording is `DictationRecord.stageMillis[.arm]`.
  Subject to the `log show` unreliability footgun below — capture it live via `log stream --predicate
  'category == "audio"'`. A disposed unit's render callback cannot fire (`AudioOutputUnitStop` is synchronous), and a
  stray late buffer is a no-op because the RT handler guards on the `capturing` atomic (set false at teardown
  before the unit is stopped). Because bring-up is async, `handleCommit` before `captureStarted` cancels the not-yet-live attempt rather
  than queueing a commit against audio that was not recording yet. Two idle HAL listeners
  (`kAudioHardwarePropertyDefaultInputDevice` + the device list) re-prewarm on a device change while idle;
  **while recording**, raw AUHAL posts no `AVAudioEngineConfigurationChange`, so a per-capture listener on
  the BOUND device (`DeviceIsAlive` + `NominalSampleRate` + `BufferFrameSize`, for disconnect, a Bluetooth
  A2DP↔HFP flip, and a mid-capture IO-period growth past scratch) restarts capture into the same file on the
  control queue, bounded by `maxConfigRestarts`.
- **The recording HUD is key ⟺ recording.** Synthesized ⌘C/⌘V/Return go to the key window, so the
  HUD (`KeyablePanel`) must relinquish key focus before any selection-capture ⌘C or paste ⌘V —
  `HUDController.relinquishKeyFocus()` runs in `finishInsertion`, in `rewriteSelection`, in
  `pasteLast`, and on every non-recording `render`.
  `CorrectionPanelController`/`HistoryController` solve the same problem by capturing `previousApp`
  + selection first, then orderOut → activate → wait → paste.
- **`NSPasteboard`/`NSPasteboardItem` are main-thread-only — `PasteboardSnapshot.capture` is deliberately
  SYNCHRONOUS `@MainActor`, and must stay both.** `data(forType:)` on a promised/lazy flavor drives
  CFPasteboard's cross-process XPC bridge; doing that off-main corrupts the CF object graph and
  **PAC-traps** (`EXC_BREAKPOINT` in `__CF_IS_OBJC` ← `_CFXPCCreateXPCObjectFromCFObject`) — a shipped crash,
  and AppKit itself logs `NSPasteboard: synchronous promise fulfillment requested from a background thread!`
  right before it. An earlier build ran the render off-main under `runWithDeadline` to keep the HUD smooth;
  that is the bug. **`runWithDeadline`/`runWithBudget` are the WRONG tool for any AppKit work, twice over**:
  `operation` is `@escaping @Sendable`, so it does NOT inherit the caller's `@MainActor` and lands on the
  cooperative pool; and on expiry they only *abandon* it — the abandoned render kept touching
  `NSPasteboardItem`s that the main actor then invalidated via `clearContents()`/`writeObjects`. Being
  synchronous is load-bearing beyond thread affinity: with no suspension point, nothing can rewrite the
  pasteboard *between* two flavors and no render outlives the call, so a single `capture` is atomic against
  the clipboard. The **cost is accepted, not overlooked**: macOS exposes no bounded or cancellable pasteboard
  read (`NSFilePromiseReceiver` is file-promises-only; there is no timeout knob on CFPasteboard's XPC), so
  `renderBudgetSeconds` (0.25) can only be checked BETWEEN flavors — the aggregate is bounded, but one wedged
  flavor blocks main for its whole render. `beginScratchPaste` threads ONE deadline through all four
  stabilize captures, else that stall multiplies by 4. Tests pin both halves
  (`lazyFlavorsThatBlowTheBudgetFallBackToPlainText`, `aSlowFlavorOutlastingTheBudgetStillRendersToCompletion`)
  plus a data-provider probe asserting the render ran on the main thread. Two traps when touching this:
  nested types do **NOT** inherit the enclosing `@MainActor` (`PasteboardSnapshot` sits inside `@MainActor
  enum TextInserter` yet its members are nonisolated unless annotated — `capture`/`restore`/`restoreFull` each
  say so explicitly); and a `SlowDataProvider`-style test now sleeps **on the main actor**, so keep such
  delays just over the budget (~0.3 s, never seconds) or it starves every other `@MainActor` test in the suite.

---

## Read order

1. `docs/development/principles.md` — the 9 engineering/product principles. Govern every decision.
2. `docs/development/design.md` — the architecture: vision, invariants, pipeline (§4.2 ordering is load-bearing),
   modes & two-phase routing (§4.3), context (§4.4), insertion (§4.5), storage/versioning (§5).
3. `docs/development/roadmap.md` — build status and the remaining (unbuilt) work.
4. `docs/development/ui_design.md` — the UX contract (first run §2, HUD §5, menu §6, Settings §7, History §8).
   User-facing behavior here is normative; implementation does not override it.
5. `docs/development/ui_components.md` — the shared widget/semantic-term vocabulary. Reuse it; don't invent
   competing badges or status words.
6. `docs/reference/config_schema.md` — on-disk TOML/file formats, the seeded starter modes.
7. `docs/development/prompt_design.md` — LLM rewrite prompt structure (Gemini 2.5 Flash floor).
8. `docs/development/icon_design.md` — app icon / menu-bar glyph direction.
9. `docs/development/competitors.md` — competitive landscape and STT-engine survey.

---

## Repo layout

```
keyscribe/
  AGENTS.md            # this file (CLAUDE.md is just `@AGENTS.md`)
  Package.swift        # SwiftPM: KeyScribeKit (pure logic) + KeyScribe (app) + tests
  Sources/
    KeyScribeKit/        # pure, OS-free logic (TDD red→green)
    KeyScribe/           # the menu-bar app: adapters + SwiftUI/AppKit + main
  Tests/KeyScribeKitTests/ # pure-logic unit tests
  Tests/KeyScribeTests/    # app-target tests (@testable import KeyScribe) — OS-edge orchestration via DI seams
  Makefile             # task front door — `make help` lists build/run/release/test/setup/…
  make-app.sh          # → KeyScribeDev.app (dev variant, default; self-signed — see BUILD.md)
  release.sh           # → notarized production KeyScribe.app + DMG (./release.sh patch|minor|major)
  scripts/             # dev helpers: setup-dev-signing.sh, reset-permissions.sh, verify-live.sh,
                       #   render_app_icon.swift (all reachable via make targets)
  docs/                # user docs, plus development/reference specs
  corpus/              # recorded-speech corpus + replay harnesses (committed kit; *.wav + results.json
                       #   gitignored — your own voice). One folder per sub-corpus = a manifest + flat
                       #   <id>.wav (the runner convention). Sub-corpora: stt/ engine WER benchmark
                       #   (→ KeyScribe --benchmark corpus/stt, ranked by compare.sh), commands/ spoken-
                       #   command regression (→ KeyScribe --commands-check corpus/commands), voices/
                       #   multi-voice TTS/human studies. Record: bash corpus/record.sh [--commands].
```

---

## Toolchain

- macOS 26.x, arm64, **Swift 6.3+**, **Xcode.app installed** (`sudo xcode-select -s
  /Applications/Xcode.app` to select it for signing/notarization).
- **FluidAudio** SPM dep; Parakeet weights download at runtime.
- Local **oMLX** for LLM iteration (OpenAI-compatible): `http://127.0.0.1:11234/v1`, key in
  `~/.omlx/settings.json`. The **Gemini 2.5 Flash** floor still wants a real pass before shipping
  LLM features.
- Swift 6 **strict concurrency** applies. The patterns for AppKit/CGEvent/AX code are
  `nonisolated(unsafe)`, `@MainActor`, `MainActor.assumeIsolated` — see the adapters in
  `Sources/KeyScribe/Adapters/`.
- **Logging:** `os.Logger` under subsystem `com.keyscribe.app` (categories in
  `Sources/KeyScribe/Log.swift`: `bias`, `context`, `models`, `insertion`, `audio`). Footgun: `log show` /
  `log stream` do **not** reliably surface these on this machine even when the strings are compiled
  in — don't trust "no log output" as "the code path didn't run." The reliable ground-truth for
  verifying insertion is a **clipboard-marker probe**: `printf MARKER | pbcopy`, dictate, then
  `pbpaste` — untouched marker + nothing inserted ⇒ AX false-`.success` data loss; marker replaced ⇒
  the clipboard-fallback path ran; text inserted + marker intact ⇒ the paste path (saves/restores).

---

## Platform facts (build on these; don't re-derive)

- **STT (Parakeet/FluidAudio):** reload-from-cache ~0.13s, transcribe 74–90ms, resident
  ~27–38MB on short speech. Eviction is nearly free. API:
  ```swift
  import FluidAudio
  let models = try await AsrModels.downloadAndLoad(version: .v3)
  let manager = AsrManager(config: .default)
  try await manager.loadModels(models)
  var decoderState = try TdtDecoderState()
  let result = try await manager.transcribe(url, decoderState: &decoderState)  // result.text
  ```
- **Insertion:** **paste is primary** — it lands across Electron/Chromium/native and undoes in a
  single ⌘Z. AX-insert/type are unreliable (secondary only; AX is verified by reading the field
  value back, else falls back to paste).
- **Permissions = Accessibility + Automation (+ Microphone). Input Monitoring is NOT used.**
  Accessibility covers post ⌘V/⌘C + AX reads **and** the modifier-only trigger event tap;
  Automation is browser URL via AppleScript (requested only when a mode opts into URL context);
  Microphone is capture.
  - **The hotkey mechanism is split by trigger type, and no path needs Input Monitoring**
    (`HotkeyMonitor` + `CarbonHotKeys`):
    - **Modifier-only triggers** (Fn / right-Option / right-Command / right-Control / Hyper) → a
      `.listenOnly` `CGEventTap` watching `.flagsChanged` **and `.keyDown`** (keyDown drives the
      right-side "chord wins" abort — see `resolveSoleModifier`/`handle`). Once Accessibility is granted,
      that session tap runs on **Accessibility alone** (we never request Input Monitoring) and never
      consumes a keystroke. `.listenOnly` (not `.defaultTap`) because we never modify/consume the event:
      a listen-only tap is delivered async, so the window server does NOT block the system input stream on
      our callback — a busy/wedged main thread can never hold global input hostage, it only delays our own
      observation.
      **Footgun — the authorization is one-directional, so `start()` gates `tapCreate` on
      `AXIsProcessTrusted()`:** calling `tapCreate` *before* the grant not only fails, it makes tccd write
      a *denied* `ListenEvent` (Input Monitoring) record and pop a spurious Input Monitoring prompt; that
      denied record then suppresses the tap **permanently** — even after Accessibility is later granted —
      until ListenEvent is reset. The gate (`HotkeyMonitor.start()`) makes that impossible, and
      `relaunchForPermissionSetup()` runs `tccutil reset ListenEvent` (via `ResetTool.resetInputMonitoring`)
      before the permission relaunch to heal installs poisoned by a pre-gate build (harmless no-op on a
      clean machine). Never call `tapCreate` untrusted, and never "simplify" the gate away.
      Verified fact (macOS 26.5, 2026-07-12): **Accessibility subsumes listen-event access** — a
      `.listenOnly` session tap DOES receive `.keyDown` with only Accessibility granted and **no**
      Input Monitoring grant (`CGPreflightListenEventAccess()` reads `true` from the Accessibility grant
      alone; 65 physical keyDowns delivered to the tap while KeyScribe was absent from the Input
      Monitoring list). That is what makes the right-side "chord wins" abort real on every install — it
      is NOT dead code. (An earlier note here claimed the tap was "deaf to keyDown without Input
      Monitoring"; that was stale — it conflated the *untrusted*-`tapCreate` poisoning above, which is
      still real and still gated, with steady-state delivery.) Chords still ride `CarbonHotKeys` and ESC
      still rides the HUD local monitor — by design (no permission, guaranteed suppression from the
      focused app), not because the tap can't see keyDown. Re-verify if the macOS TCC model changes.
    - **Chord triggers + the Add-Dictionary / Add-Replacement action shortcuts** (key + modifiers,
      e.g. ⌃⌥E) → **`RegisterEventHotKey`** (Carbon, `CarbonHotKeys`). No permission at all: the OS
      dispatches the chord and suppresses it from the focused app. Delivers
      `kEventHotKeyPressed`/`Released`, so hold/tap gestures work. Cannot register a bare
      modifier-less key (needs ≥1 modifier).
    - **Mouse-button triggers** (`mouseN`, button ≥ 2 — middle / thumb buttons) → a **`.defaultTap`**
      `CGEventTap` watching `.otherMouseDown`/`.otherMouseUp` (`MouseEventTap`). Mouse-button events,
      unlike `keyDown`, are delivered under **Accessibility alone** — no Input Monitoring (verified
      against VoiceInk/OpenWhispr, both Accessibility-only). It is **active/consuming** (returns `nil`
      for a bound button) so the button does not also fire its normal action; the bound button is
      therefore swallowed globally while the app runs, the same trade Wispr/Superwhisper make.
      **Footgun: this is the ONE consuming tap, and it must NEVER run on the main run loop.** An active
      tap is synchronous (the window server blocks on the callback); the original freeze was a
      `.defaultTap` on the *main* thread held hostage by a wedged main thread (Bluetooth A2DP→HFP audio
      bring-up). `MouseEventTap` runs the tap on a **dedicated run-loop thread**; its callback only reads
      a lock-guarded `Set<Int>` and hands the edge to main async — it touches no audio/AX/SwiftUI, so a
      wedged main thread (a different thread) can never block it. The button set is emptied while a
      `HotkeyRecorder` is capturing, so a mouse button can be recorded as the raw click. Mouse cannot ride
      Carbon (keyboard-only) or the modifier tap (listen-only can't consume).
    - **ESC-to-cancel** → handled as a **local** keystroke by the recording HUD, made key only while
      recording (see the HUD-is-key footgun above). A local `NSEvent` monitor needs no permission.
- **Context:** frontmost bundle id always available; **⌘C→pasteboard is the universal selection
  capture**; **browser URL via AppleScript/Apple Events, NOT AX** (AX returns nil on Chromium).
  Footgun: synthesized ⌘C has a settle-time race — wait for the pasteboard changeCount to bump (or
  retry) before reading the selection.
- **TCC verdicts are read at launch and cached for the process lifetime** — a grant/revoke needs an
  app **relaunch** to take effect. Toggling off→on does **not** rebind a grant's `csreq`; only
  remove+re-add or `tccutil reset <service> com.keyscribe.app` rebinds it to the current signature.
- **Token-fencing:** `⟦SN:…⟧` nonce tokens survive LLM rewrite (verified against the Gemini 2.5
  Flash floor, 24/24 across hard rewrite shapes).

---

## STT engines

KeyScribe ships **8 curated models across 5 engine kinds**, all with in-app download/install:
Parakeet TDT v3 (English default), Parakeet TDT-CTC 110M, Whisper Large v3 Turbo,
Whisper Small (English), Apple SpeechAnalyzer, Qwen3-ASR 0.6B, Qwen3-ASR 1.7B, and
Moonshine Base (English). **Four are bias-capable** — both Qwen3 models (native context) and both
Whisper models (prompt tokens); **Parakeet, Apple, and Moonshine have no recognition bias**
(`supportsRecognitionBias = false`). The dictionary still prefers a user's spellings on **every**
engine via after-transcription recovery (`FuzzyStage`), which now runs whenever the mode's merged
dictionary is non-empty — no per-engine toggle. Engines are
wired through a single **`EngineRegistry`** descriptor list (catalog ↔ constructor) that the
provider, download path, install reconcile/delete, and the benchmark all derive from — adding an
engine is one descriptor + one catalog entry. `load(progress:)` is on the `SpeechEngine` protocol;
each engine owns its install footprint (`installDirNames` / `installState`); audio decode is shared
(`AudioDecoder`).

A dev **STT benchmark** (`KeyScribe --benchmark <dir> [--engines …]`, runner + pure scoring in
KeyScribeKit) measures WER (biased vs unbiased) / term recall / RTF over recorded clips. On a
107-clip single-voice corpus the top engines (Whisper Large v3 Turbo, Qwen3-ASR 1.7B, Whisper
Small) cluster around 5.7–6.0% biased WER; the weakest (Moonshine) is ~15%. These numbers are
speaker/mic/room dependent — reference table + caveats in
`docs/reference/stt_benchmarks.md`, reproduction in `corpus/stt/README.md`. The shipped list order is
**recommended-first, grouped by engine family** (catalog order in `SpeechModelCatalog.all`), not
benchmark rank — a single-voice ranking can't carry that authority and would fight the
"Recommended" badge on the small default.

### Silence / no-speech behavior — exercise every new model

**First line of defense: the audio-side no-speech gate.** A finished take runs once through Silero VAD
(`SpeechPresenceDetector` adapter over FluidAudio's `VadManager`; verdict logic in the pure
`SpeechPresenceGate`, KeyScribeKit) BEFORE transcription — `DictationController.gateSuppressesNoSpeech`,
at the commit call site after `finishDraining()` and before `finalizeStreamingIfActive`. If no chunk's
speech probability clears `0.30` (take-level max; a digital-silence peak short-circuits without even
invoking the model), the dictation is suppressed with the same `.noSpeech` UX as an empty transcript —
nothing is transcribed or pasted. This closes the whole engine-silence-artifact class in one move
(Qwen3's biased-dictionary echo on silence, Whisper's `Thank you.`, Apple's `No`), which a string
denylist provably cannot (see below). The gate **fails open**: a missing VAD model, an error, or a
timeout proceeds to transcription unchanged, so the transcript-level checks below remain the mandatory
second line. The ~1 MB model downloads alongside speech models into the shared `models/silero-vad/`.

Because the gate is fail-open, **every STT model added to the catalog must STILL be exercised against
silent/near-silent audio before it ships** — the artifact table below is the second line of defense, not
optional. Engines disagree wildly on what they emit for "nothing was said" and KeyScribe's `.noSpeech`
guard (`DictationMachine.outcomeForTranscript`) keys off the **heard (raw) transcript**, not the final
text: silence short-circuits only because its heard transcript is whitespace-empty, so any non-empty
artifact an engine emits gets pasted, atomically-undoable, and (worse) is indistinguishable from a real
short dictation. (The guard deliberately does **not** whitespace-test the final text — that
would drop a command-only utterance whose output is a bare control char like `"\n"`; it checks the final
text only for emptiness.) Reproduce with the `--raw` benchmark over generated silence:

```bash
# 16k mono clips: pure silence at several durations + quiet hiss + a faint blip
for d in 1 2 3 5; do ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t $d -c:a pcm_s16le sil_${d}s.wav; done
ffmpeg -f lavfi -i "anoisesrc=r=16000:a=0.02:d=3:seed=33" -c:a pcm_s16le hiss.wav
# manifest.json: { "schemaVersion": 1, "clips": [{ "id": "<wav-basename>", "file": "<wav>", "text": "" }, …] }
./KeyScribeDev.app/Contents/MacOS/KeyScribe --benchmark <dir> --engines <new-id> --raw   # RAW\t<engine>\t<clip>\t<literal output>
# And exercise the gate itself over the same clips (verdict + max probability + latency per clip):
./KeyScribeDev.app/Contents/MacOS/KeyScribe --vad-probe <dir>   # silences/hiss → suppressed; real speech → 100% speech
```

Empirically observed no-speech output (2026-07-01, one machine — deterministic per fixed input, but
**content-dependent** across different silences, so treat as representative, not exhaustive):

| Engine | Output on silence/near-silence |
|---|---|
| Parakeet TDT v3 / TDT-CTC 110M | `""` (clean empty — greedy TDT discards blanks) |
| Qwen3-ASR 0.6B | `""` |
| Moonshine Base (en) | `""` (but upstream can loop-repeat on short audio) |
| Whisper Small (en) | bracketed marker `[BLANK_AUDIO]`, **and** parenthetical sound-tags e.g. `(water running)` |
| Whisper Large v3 Turbo | lexical hallucinations: `Thank you.`, `.`, `...` |
| Qwen3-ASR 1.7B | rare lexical, e.g. `嗯。` (CJK) |
| Apple SpeechAnalyzer | rare lexical, e.g. `No` |

**Load-bearing conclusion: a string denylist cannot solve this.** The only *safe* strings to strip are
non-lexical annotations no user dictates — bracketed/parenthetical tags like `[BLANK_AUDIO]`,
`(water running)`, `[Music]` (note WhisperKit **does** emit `[BLANK_AUDIO]` here despite upstream docs
calling it a whisper.cpp-only construct — verified empirically, do not trust the docs). The dangerous
outputs (`Thank you.`, `No`, `.`) are real words and must **not** be denylisted — filtering them would
silently drop legitimate one-word dictations. The robust guard for those is the **audio-side VAD pre-gate**
above (was there speech in the audio?) upstream of the transcript, not string matching — now shipped
(`SpeechPresenceGate` / `SpeechPresenceDetector`). This annotation collapse remains for the safe
bracketed/parenthetical strings and as the gate's fail-open backstop. Re-run this the moment a model is
added or an STT dep is bumped — the marker set is engine- and version-specific, and the gate being
fail-open means a new engine's artifacts must still be swept. Validated separation (2026-07-09, one
voice): over `corpus/stt` (107 clips) every clip read `speech` with a minimum take-level max probability
of 0.397 (margin 0.097 above the 0.30 threshold); generated silence/hiss all read `noSpeech` (hiss max
probability 0.198) — a clean gap around 0.30.

**A streaming session is a DISTINCT no-speech path — sweep it separately.** An engine's `makeStreamingSession`
feed→finalize can emit different silence artifacts than its batch `transcribe`, so a model that ships a
streaming path (`supportsStreaming=true`) must be exercised against silence **both ways**. Use
`--benchmark <sil-dir> --engines <id> --streaming --raw` (raw dumps the literal streamed output per clip)
alongside the batch `--raw`. Include a **≥5 s** silence/hiss clip: the real dictation path defers session
creation past the `StreamingStartPolicy` threshold (4 s), so only clips longer than that actually open a
session live — the benchmark's streaming replay opens one for every clip, so it covers both. (2026-07-04,
Apple: streaming output was byte-identical to batch — clean-empty except a deterministic `No` on 3 s
silence, the same documented Apple lexical artifact — so streaming added no new marker class. Do not assume
that generalizes; a slower/looping engine like Moonshine could differ, which is one more reason its
streaming is disabled.) The no-speech gate also covers the streamed path: it runs at commit on the
finished take before `finalizeStreamingIfActive`, so a silent streamed session is suppressed there (its
partials are never inserted before commit) and its driver is cancelled through the normal terminal — the
gate is engine- and path-independent, but the per-engine streaming sweep still stands because the gate is
fail-open.

### Recognition bias — the distractor false-fire gate (exercise every bias-capable model)

**Any engine that ships `supportsRecognitionBias = true` must pass the distractor false-fire sweep
before bias ships enabled.** Run `--benchmark corpus/distractors` (a real phrase acoustically adjacent
to a dictionary term, term never spoken) and `--benchmark corpus/distractors --fuzzy`. The gate is
**substitution fires ≈ 0** over the engine's unbiased baseline — the `sub(bias)` column, fires whose
words are absent from the reference (different words the dictionary put in the speaker's mouth).
**Orthographic snaps are reported but tolerated**: a fire whose words ARE in the reference is the
dictionary snapping spacing/casing ("text field" → "TextField"), which is the dictionary system's
intended behavior — after-transcription recovery does the same by design. The bar and the
counter-example are in `agent_notes/fable_bias_test/results.md`: Qwen3 native context = 0 substitution
fires (kept); the removed Parakeet CTC-WS spotter substituted on 53% of ordinary sentences (removed).
The `supportsRecognitionBias` seam, the `biasTerms` plumbing through the pipeline, and this corpus ARE
the re-entry path for a future engine that biases cleanly — nothing else is kept for that purpose; the
removed spotter lives in git history only.

### Forked / pinned STT deps

Two forks + two upstream deps (one a pinned binary); the forks work live and cost nothing day-to-day:
- **WhisperKit** → `rsperko/argmax-oss-swift` (upstream v1.0.0): a one-line `!isPrefill` fix for the
  empty-output-with-`promptTokens` bug (#372) that breaks Whisper bias in every stock release.
  Depending on just the `WhisperKit` product keeps Vapor/openapi out of resolution (gated behind
  `BUILD_ALL`). Still essential: upstream added `!isPrefill` guards elsewhere but NOT on the
  `isSegmentCompleted` break our patch guards, so #372 is live for bias (verified 2026-07-08).
- **FluidAudio** → `FluidInference/FluidAudio` (upstream, **no fork**): provides Parakeet TDT
  transcription. Historical: KeyScribe once paired it with FluidAudio's **CTC-WS** keyword spotter
  (NeMo constrained-CTC) for Parakeet recognition bias, gated by `spotterRescueEnabled`. That spotter
  was **removed** (2026-07-09) — it false-fired a dictionary term into a majority of ordinary
  sentences (`agent_notes/fable_bias_test/`); Parakeet now transcribes **TDT-only** and ignores
  `biasTerms` (`supportsRecognitionBias = false`), with the companion CTC download and disk footprint
  gone.
- **speech-swift (Qwen3-ASR)** → `rsperko/speech-swift` (upstream `soniqo/speech-swift`, package
  `Qwen3Speech`): the fork only gates the `AsrBenchmark`/`AudioServer` targets behind `BUILD_ALL`
  so stock `speech-swift`'s `argmaxinc/WhisperKit` doesn't collide with our WhisperKit fork.
  Qwen3-ASR bias is **native** (`Qwen3DecodingOptions.context`), so no source patch is needed.
- **Moonshine** → `moonshine-ai/moonshine-swift` (no fork): ONNX Runtime ships as a prebuilt
  `Moonshine.xcframework` binaryTarget. No on-device bias path, so `supportsRecognitionBias = false`
  and dictionary recovery handles close matches after transcription.

**MLX metallib is a hard runtime requirement.** Qwen3-ASR (MLX) crashes ("Failed to load the default
metallib") without `mlx.metallib` beside the executable. `make-app.sh` builds it from the
speech-swift checkout's kernels and bundles+signs it into the `.app`; the **Metal Toolchain**
(`xcodebuild -downloadComponent MetalToolchain`) is a build-time prereq.

---

## Build & storage

Top-level SwiftPM (`Package.swift`): `Sources/KeyScribeKit` (pure) + `Sources/KeyScribe` (app) +
`Tests/KeyScribeKitTests` (pure-logic) + `Tests/KeyScribeTests` (app-target via
`@testable import KeyScribe`, for OS-edge regression through DI seams). Bundled into an LSUIElement
`.app` by `./make-app.sh` — the **dev** variant signs with a stable self-signed cert (**`KeyScribe
Local`**) for persistent TCC, else ad-hoc; it **ignores** `KEYSCRIBE_SIGN_ID` /
`CODESIGN_IDENTITY` (those are the release Developer ID identity, so an `.envrc` for `release.sh`
never leaks into dev). Full from-source build, prerequisites, and signing live in **`BUILD.md`**.

**Two build variants** (`KEYSCRIBE_VARIANT`, default `dev`): `./make-app.sh` builds the isolated
**KeyScribeDev.app** (`com.keyscribe.app.dev` — its own config dir, TCC grants, and Keychain service;
orange menu-bar tint) so it runs alongside an installed production app; `./release.sh` forces the
production **KeyScribe.app** (`com.keyscribe.app`, Developer ID, hardened runtime, notarized + stapled
DMG). `./release.sh patch|minor|major` bumps the tag, builds, notarizes, and prints the publish steps —
it stops before pushing anything public. Variant plumbing: `AppVariant` (KeyScribeKit) resolved through
`KeyScribePaths`/`KeychainStore`; **downloaded models are shared** (pinned to `KeyScribe/models`, never
per-variant — the easy-to-miss part). Full detail in `agent_notes/distribution_plan` + `dev_variant`.

**Shipping a release** (`./release.sh patch|minor|major` → `make ship`): the build + double Apple
notarization (app, then DMG) takes ~10–30 min, so it is a **background + poll** job, not a foreground
one (see the global "Command Execution" discipline). Write the log to a file and `tail` it. Two resume
footguns: (1) if a `patch`/`minor`/`major` run already created the next tag, re-running with the bump
arg creates a *duplicate later* tag and errors on `tag already exists` — instead resume with a **bare
`./release.sh`** (or `make ship` with no bump) which builds from the existing tag. (2) an orphaned
`swift-package`/`swift-test` can hold a stale `.build/.lock` (it caches the PID, rechecks, but a wedged
process never clears it) and silently block all builds — if a build reports `Another instance of
SwiftPM (PID: …) is already running` for minutes, confirm that PID is dead (`ps -p <pid>`), then
`rm -f .build/.lock` and relaunch. Do not stack concurrent `make ship`/`make release` invocations:
they race on the lock and on `make publish`.

**The release gate is mandatory and enforced: `make preflight` (→ `scripts/preflight.sh`) must pass
before anything goes public.** `swift test` green is NOT sufficient — it runs on the dev build, but
releases break on what only exists in the notarized artifact (TCC grants rebinding to the new
signature, hardened-runtime entitlements, the bundled+signed `mlx.metallib`, Gatekeeper quarantine,
first-run onboarding, the permission-gated trigger matrix). Preflight runs the automated build/packaging
+ functional gates and walks the human smoke checks on the freshly-installed production app, then writes
a commit-keyed stamp (`.preflight-pass`). `scripts/publish.sh` **refuses to publish without a matching
stamp** (override: `KEYSCRIBE_SKIP_PREFLIGHT=1`, i.e. shipping unverified). `make ship` chains
release → preflight → publish. Full contract + rationale: `docs/development/release_testing.md`.

`KeyScribe.entitlements` (hardened-runtime) is passed by **`release.sh`** for the notarized build;
`make-app.sh`'s dev signing omits it (a teamless self-signed cert can't authorize it). Keep its XML
comments free of `--` — AMFI's strict parser rejects them. The bundle's `Info.plist` is a tracked
source at `Resources/Info.plist`; the build scripts stamp `CFBundleShortVersionString` (git tag),
`CFBundleVersion` (commit count), and the variant's bundle id/name — don't hand-edit those keys.

Config lives under `~/Library/Application Support/<KeyScribe|KeyScribeDev>/` (per variant; the
`models/` weights cache is shared), loaded once into `ConfigCache` and invalidated by an FSEvents
watcher (no per-dictation I/O). File-based storage, **no SQLite**: config
as TOML (modes/connections/dictionary/replacements), fragments as markdown+YAML, history as
JSONL-per-day, downloaded STT weights consolidated in `models/` (`docs/reference/config_schema.md`). Every persisted
*config* file carries `schema_version`; older versions are normalized on read (`docs/development/design.md` §5.1);
`models/` is runtime-downloaded, never committed.

**Config migrations — there is no migration *framework*, so don't assume one.** `ConfigDecode.table`
only **gates** versions (it rejects a file newer than the app; it does not transform). "Migrating
forward" is whatever the type's `init(from:)` does on read — almost always additive `decodeIfPresent ??
default`, re-derived from `schema_version` on **every** load, never a recorded one-shot. Consequences a
future migration must respect: (1) a migration is an **idempotent read transform**, not a step that
runs once — a read-only old file stays its old version on disk until something rewrites it, and gets
re-normalized every read; (2) **there is no step chaining** — the *current* decoder must understand
**every** still-supported old version directly (a user can jump v1→v3 without ever running v2's code);
(3) **removing a field is free** — the key is just ignored on read and dropped on next write (this is
how `default_mode_id` was retired). Where a migration genuinely must run **once** (e.g. the
Plain-Dictation→Direct replacement in `ModeStore.ensureSystemModes`), it keys off a durable artifact —
the presence of `_direct.toml` — as its marker, which means **it will not re-run**. If you add a
one-shot migration that must re-run after a later change, that file-presence marker is *not* enough; add
an explicit migration flag (e.g. in the seed ledger) instead.

This repo has a **normal git origin** (it is *not* shop/world) — plain `git`/`gh` apply.

---

## Feature flags

Ship in-development features behind an opt-in toggle, exercise them, then roll them out by deleting
the flag. The single source of truth is the **`Feature`** type (`Sources/KeyScribeKit/Features.swift`) —
a struct whose `static let` catalog (listed in `allCases`) is the set of flags;
state lives in the global `settings.toml` `[features]` table as **deviations only** — it stores just
the ids the user turned on, so an absent (or unknown, or pruned) id means **off**. Flags are strictly
opt-in (no per-flag default-on) and appear in every build under **Settings → Advanced → Experimental
Features** (the section hides itself when there are no flags).

- **Read a flag (code):** `settings.features.isEnabled(.myFlag)` — `.myFlag` is a real `static let`, so a
  typo won't compile. `Settings` is already threaded through `AppDelegate` → `DictationController`; just gate at
  the seam: `if settings.features.isEnabled(.myFlag) { … }`. **Never branch the pipeline on flag
  identity beyond the single gate** — same rule as modes (`principles.md` §2).
- **Set a flag (tests):** build the state type-safely, no strings —
  `var s = Settings.defaults; s.features.setEnabled(true, for: .myFlag)`, or construct directly with
  `Settings.Features([.myFlag: true])`. Then assert `s.features.isEnabled(.myFlag)` or drive the gated
  code path.
- **Add a flag:** add one `static let` to `Feature` with its `id` (stable, unique snake_case TOML key — never
  rename once shipped; `FeaturesTests.featureIdsAreUnique` guards collisions), `title`, and `summary`, and
  append it to `allCases`. The Advanced toggle renders automatically; no UI code to touch.
- **Roll out / retire:** delete the `static let` and its `allCases` entry, and make the gate unconditional
  (or delete the dead branch). A stale id left in a user's `settings.toml` is ignored and dropped on the next write.

The catalog currently holds a single flag, `streamingTranscription` (the first shipped flag); before it,
`allCases` was empty, and it returns to empty once every flag is rolled out. `Feature` is a **struct** with a
`static let` catalog rather than an enum precisely so that empty state does not read to the compiler as
unreachable code, and so the Advanced section can hide itself when `allCases` is empty. When you add a flag,
also add per-flag tests — default-off fallback, override persistence, and off-elision.

---

## Working discipline

- **No commits, branches pushed, or PRs without explicit user instruction.** No AI self-references
  anywhere in repo content (commit messages, code, docs).
- **ZERO code comments** unless explicitly requested — self-documenting names and structure.
- **TDD red→green** for pure logic; thin adapters + integration tests for OS edges. Keep building
  the OS-free core in `KeyScribeKit` (pipeline, mode resolution, tokenization, gate, regex via
  `RegexCache`, config models) test-first; OS edges (AUHAL capture, paste, CGEvent hotkeys, SwiftUI)
  are thin adapters in `Sources/KeyScribe`.
- **File-based storage, no SQLite** — everything under `~/Library/Application Support/KeyScribe/`.
- **Reuse the UI vocabulary** in `docs/development/ui_components.md`; never overstate privacy (no "secure/safe/
  private" for best-effort redaction — say what actually happens).
- **Never hardcode the product name in user-facing copy — use `Branding.appName`** (resolves from the
  running bundle: "KeyScribe" prod, "KeyScribeDev" dev, the bundle name for a `custom` rebrand). The
  literal "KeyScribe" lives in exactly one place, `AppVariant.production.displayName`; everything else
  interpolates `\(Branding.appName)`. This is the white-label seam (with `make-app.sh
  KEYSCRIBE_VARIANT=custom` + the `__BUNDLE_NAME__` placeholder in `Info.plist`); a hardcoded name
  breaks a downstream rebrand and shows the wrong name in the dev build.
- When a design choice leans on a principle, note it inline as the docs do.
