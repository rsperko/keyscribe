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
- **The only outbound network call is an explicit BYOK LLM rewrite**, over a redacted payload.
- **No telemetry, no analytics.** Speech, transcripts, and usage are never collected.
- **Dictation is batch (commit-on-release) and inserts atomically** — one ⌘Z undoes the whole
  dictation.
- **No app/mode identity in source.** No `if app == "Slack"`, no per-app presets. A Mode is a
  named bag of config a generic pipeline executes (`principles.md` §2). Adding a mode = adding
  data, never code.

---

## Footguns (read the cited section before touching the area — these silently corrupt or leak)

- **Pipeline order is fixed and load-bearing** (`design.md` §4.2.1): **verbatim tokenizes FIRST**
  (before the text stages, so a verbatim span is protected from everything except STT), the text
  stages run, **redaction tokenizes LAST** (just before the LLM), and restore is each command's
  `post` in strict **reverse/LIFO**, on every path (incl. no-LLM). Stages are commands with
  `apply`/`post`; one-way text stages leave `post` a no-op. Wrong order silently corrupts output or
  leaks a redacted span — never improvise it.
- **Tokenization is safety, not cosmetics.** The token→original map is **in-memory only, never
  logged or written to history**, and the **post-LLM validation gate** (every issued `⟦SN:…⟧`
  returns exactly once; non-empty) is a hard check, not normalization: a dropped redaction token
  leaks the protected span, a dropped verbatim token corrupts the insert. On failure → one
  stricter retry → else local fallback + HUD notice (`design.md` §4.2).
- **Privacy mode and context are mutually exclusive.** When a mode's privacy toggle is on, the
  context checkboxes are **forced off and locked** — the redacted transcript is the only user
  content that may leave the machine (`design.md` §4.4).
- **Dictionary is a hint, replacements are not protected.** Dictionary terms only tell the LLM
  "valid, not a misspelling" (it may still transform them); replacements flow into the LLM and
  can be rewritten. Only **nonce tokens** are guaranteed to survive the rewrite (`design.md` §4.2).
- **Credential material is never persisted in config.** Saved API keys live in Keychain and TOML
  stores only `key_ref`; command-generated bearer tokens are in-memory only. `token_command` stores
  the command to run, not the token material itself (`config_schema.md`).
- **Edit-in-place is a capability, not a special mode** — any mode can be `source=selection` /
  `output=replace_selection`; ⌘C→pasteboard is the selection capture, AX is a native-only bonus
  (`design.md` §4.3).
- **Commit-on-release drains the tail before stopping — do not revert to an immediate stop.** The
  AVAudioEngine tap accumulates `bufferSize` frames before each callback, so at release the buffer
  holding the final word is still filling and undelivered; tearing the engine down right then clips
  it. `handleCommit` flips the HUD to *transcribing* and then `await`s
  `AudioCapture.finishDraining()`, which keeps the engine running until a delivered buffer's host
  time covers the release instant (`TailDrainGate`, with a buffer-count fallback for invalid
  timestamps and a 300 ms backstop), and only then tears the engine down (`teardownAndFinalize`, which
  closes the WAV only after the tap is removed so no in-flight write races the finalize). **`stop()` is
  the immediate, audio-discarding teardown** — keep it for `cancel()`/over-limit abort only; the commit
  path must use `finishDraining()`. `stop()` also force-resumes any pending drain so a direct stop never
  strands the awaiter. `bufferSize` is 1024 (~64 ms @16k) to keep the worst-case undelivered tail
  short. The `wav … drain=Xms` debug log reports the actual flush time (≈300 ms means the backstop
  fired). Don't reorder the HUD flip after the await — the drain latency must stay invisible.
- **AVAudioEngine bring-up/teardown run off the main thread on a serial queue, watchdogged — never move
  them back onto `@MainActor`.** `engine.start()`/`stop()`/`installTap`/`removeTap` can block for a long
  time (or indefinitely) on a transitioning device — classically a Bluetooth headset forced from A2DP
  into HFP the moment capture opens an input stream — and doing that on the main thread froze the whole
  app *and* (via the event tap) global input. `AudioCapture` confines every engine control call to a
  private serial `controlQueue`; `start()` is `async` and bounded by a ~2 s watchdog (`runWithDeadline`).
  On a timeout it marks the engine *suspect*, abandons the wedged call on its (now-orphaned) queue, and
  the next dictation rebuilds a fresh engine + queue — so the healthy path keeps reusing the prewarmed
  engine (no fresh build per dictation) and a wedge degrades to a graceful "Could not start the
  microphone" instead of a hang. A tap buffer carries the engine `generation` so a wedged engine that
  finally unblocks can't write into a newer recording. Because bring-up is async, `handleCommit` before
  `captureStarted` cancels the not-yet-live attempt rather than queueing a commit against audio that was
  not recording yet. A `kAudioHardwarePropertyDefaultInputDevice` listener re-prewarms on a device change
  while idle (no `AVAudioEngineConfigurationChange` fires while stopped), keeping the prewarmed engine's
  binding fresh.
- **The recording HUD is key ⟺ recording.** Synthesized ⌘C/⌘V/Return go to the key window, so the
  HUD (`KeyablePanel`) must relinquish key focus before any selection-capture ⌘C or paste ⌘V —
  `HUDController.relinquishKeyFocus()` runs at the top of `transcribeAndInsert`, in
  `finishInsertion`, in `pasteLast`, and on every non-recording `render`.
  `CorrectionPanelController`/`HistoryController` solve the same problem by capturing `previousApp`
  + selection first, then orderOut → activate → wait → paste.

---

## Read order (design docs live in `docs/`)

1. `principles.md` — the 9 engineering/product principles. Govern every decision.
2. `design.md` — the architecture: vision, invariants, pipeline (§4.2 ordering is load-bearing),
   modes & two-phase routing (§4.3), context (§4.4), insertion (§4.5), storage/versioning (§5).
3. `roadmap.md` — build status and the remaining (unbuilt) work.
4. `ui_design.md` — the UX contract (first run §2, HUD §5, menu §6, Settings §7, History §8).
   User-facing behavior here is normative; implementation does not override it.
5. `ui_components.md` — the shared widget/semantic-term vocabulary. Reuse it; don't invent
   competing badges or status words.
6. `config_schema.md` — on-disk TOML/file formats, the seeded starter modes.
7. `prompt_design.md` — LLM rewrite prompt structure (Gemini 2.5 Flash floor).
8. `icon_design.md` — app icon / menu-bar glyph direction.
9. `competitors.md` — competitive landscape and STT-engine survey.

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
  docs/                # the design docs (tracked product spec)
  benchmark/           # STT benchmark kit: manifest.json + record.sh + README (committed);
                       #   *.wav recordings + results.json are gitignored (your own voice).
                       #   Run: KeyScribe --benchmark benchmark [--engines a,b]
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
  `Sources/KeyScribe/Log.swift`: `bias`, `context`, `models`, `insertion`). Footgun: `log show` /
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
    - **Modifier-only triggers** (Fn / right-Option / right-Command / Hyper) → a `.listenOnly`
      `CGEventTap` watching **only `.flagsChanged`**. Once Accessibility is granted, a session tap
      observing *modifiers* runs on **Accessibility** (we never request Input Monitoring) and never
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
      Footgun: that tap is **deaf to `keyDown`** without Input Monitoring — both `CGEventTap` and
      `NSEvent.addGlobalMonitorForEvents` deliver zero key events on Accessibility alone. So chords
      and ESC can NOT ride the tap.
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
Parakeet TDT v3, Parakeet TDT-CTC 110M (English default), Whisper Large v3 Turbo,
Whisper Small (English), Apple SpeechAnalyzer, Qwen3-ASR 0.6B, Qwen3-ASR 1.7B, and
Moonshine Base (English). Seven are bias-capable; **Moonshine has no recognition bias**
(`supportsRecognitionBias = false`, dictionary recovery available in Settings). Engines are
wired through a single **`EngineRegistry`** descriptor list (catalog ↔ constructor) that the
provider, download path, install reconcile/delete, and the benchmark all derive from — adding an
engine is one descriptor + one catalog entry. `load(progress:)` is on the `SpeechEngine` protocol;
each engine owns its install footprint (`installDirNames` / `installState`); audio decode is shared
(`AudioDecoder`).

A dev **STT benchmark** (`KeyScribe --benchmark <dir> [--engines …]`, runner + pure scoring in
KeyScribeKit) measures WER (biased vs unbiased) / term recall / RTF over recorded clips. On a
16-clip real-voice corpus Qwen3-ASR 1.7B wins (0.8% WER biased, 100% term recall); 0.6B is the
speed/accuracy sweet spot; bias is decisive (Moonshine without recognition bias ~15%).

### Forked / pinned STT deps

Three forks + one pinned binary dep; the forks work live and cost nothing day-to-day:
- **WhisperKit** → `rsperko/argmax-oss-swift` (upstream v1.0.0): a one-line `!isPrefill` fix for the
  empty-output-with-`promptTokens` bug (#372) that breaks Whisper bias in every stock release.
  Depending on just the `WhisperKit` product keeps Vapor/openapi out of resolution (gated behind
  `BUILD_ALL`).
- **FluidAudio** → `rsperko/FluidAudio` (upstream 0.15.4): adds an `enableSpotterRescue` toggle to
  `ctcTokenRescore` so the weaker `ctc110m` can skip the acoustic-only rescue pass (which
  false-fired). Parakeet bias is **CTC-WS** (NeMo constrained-CTC keyword spotting).
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

`KeyScribe.entitlements` (hardened-runtime) is passed by **`release.sh`** for the notarized build;
`make-app.sh`'s dev signing omits it (a teamless self-signed cert can't authorize it). Keep its XML
comments free of `--` — AMFI's strict parser rejects them. The bundle's `Info.plist` is a tracked
source at `Resources/Info.plist`; the build scripts stamp `CFBundleShortVersionString` (git tag),
`CFBundleVersion` (commit count), and the variant's bundle id/name — don't hand-edit those keys.

Config lives under `~/Library/Application Support/<KeyScribe|KeyScribeDev>/` (per variant; the
`models/` weights cache is shared), loaded once into `ConfigCache` and invalidated by an FSEvents
watcher (no per-dictation I/O). File-based storage, **no SQLite**: config
as TOML (modes/connections/dictionary/replacements), fragments as markdown+YAML, history as
JSONL-per-day, downloaded STT weights consolidated in `models/` (`config_schema.md`). Every persisted
*config* file carries `schema_version` and migrates forward (`design.md` §5.1); `models/` is
runtime-downloaded, never committed.

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

## Working discipline

- **No commits, branches pushed, or PRs without explicit user instruction.** No AI self-references
  anywhere in repo content (commit messages, code, docs).
- **ZERO code comments** unless explicitly requested — self-documenting names and structure.
- **TDD red→green** for pure logic; thin adapters + integration tests for OS edges. Keep building
  the OS-free core in `KeyScribeKit` (pipeline, mode resolution, tokenization, gate, regex via
  `RegexCache`, config models) test-first; OS edges (AVAudioEngine, paste, CGEvent hotkeys, SwiftUI)
  are thin adapters in `Sources/KeyScribe`.
- **File-based storage, no SQLite** — everything under `~/Library/Application Support/KeyScribe/`.
- **Reuse the UI vocabulary** in `ui_components.md`; never overstate privacy (no "secure/safe/
  private" for best-effort redaction — say what actually happens).
- **Never hardcode the product name in user-facing copy — use `Branding.appName`** (resolves from the
  running bundle: "KeyScribe" prod, "KeyScribeDev" dev, the bundle name for a `custom` rebrand). The
  literal "KeyScribe" lives in exactly one place, `AppVariant.production.displayName`; everything else
  interpolates `\(Branding.appName)`. This is the white-label seam (with `make-app.sh
  KEYSCRIBE_VARIANT=custom` + the `__BUNDLE_NAME__` placeholder in `Info.plist`); a hardcoded name
  breaks a downstream rebrand and shows the wrong name in the dev build.
- When a design choice leans on a principle, note it inline as the docs do.
