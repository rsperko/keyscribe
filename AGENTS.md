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

- **Pipeline order is fixed and load-bearing** (`design.md` §4.2.1): replacements run *before*
  tokenization, tokenization is the *last* post-STT step, and restore is strict **LIFO**. Wrong
  order silently corrupts output or leaks a redacted span — never improvise it.
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
- **Secrets live in Keychain only.** TOML stores a `key_ref`, never key material
  (`config_schema.md`).
- **Edit-in-place is a capability, not a special mode** — any mode can be `source=selection` /
  `output=replace_selection`; ⌘C→pasteboard is the selection capture, AX is a native-only bonus
  (`design.md` §4.3).

---

## Read order (design docs live in `docs/`)

1. `principles.md` — the 9 engineering/product principles. Govern every decision.
2. `design.md` — the architecture: vision, invariants, pipeline (§4.2 ordering is load-bearing),
   modes & two-phase routing (§4.3), context (§4.4), insertion (§4.5), storage/versioning (§5).
3. `roadmap.md` — milestone build order M0–M7 with per-milestone checklists and exit criteria.
4. `ui_design.md` — the UX contract (first run §2, HUD §5, menu §6, Settings §7, History §8).
   User-facing behavior here is normative; implementation does not override it.
5. `ui_components.md` — the shared widget/semantic-term vocabulary. Reuse it; don't invent
   competing badges or status words.
6. `config_schema.md` — on-disk TOML/file formats, the seeded starter modes.
7. `prompt_design.md` — LLM rewrite prompt structure (Gemini 2.5 Flash floor).
8. `icon_design.md` — app icon / menu-bar glyph direction.
9. `competitors.md` — competitive landscape and STT-engine survey.

> **Note:** the design docs were moved from the gitignored `agent_notes/initial_design/` into the
> tracked `docs/` path (M1, 2026-06-20) so the real product spec ships with the repo. They are the
> real product spec, not scratch.

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
  make-app.sh          # → KeyScribe.app (LSUIElement; stable-cert or ad-hoc signed — see BUILD.md)
  docs/                # the design docs (tracked product spec)
  benchmark/           # STT benchmark kit: manifest.json + record.sh + README (committed);
                       #   *.wav recordings + results.json are gitignored (your own voice).
                       #   Run: KeyScribe --benchmark benchmark [--engines a,b]
```

(`spikes/` — throwaway M0 de-risk spikes — is kept locally but **gitignored**; its load-bearing
results were promoted into the "M0 proven facts" section below.)

Git repo initialized (M1). Do not commit without explicit user instruction.

---

## Toolchain (verified on this machine)

- macOS 26.5.1, arm64, **Swift 6.3.2**, **Xcode.app installed** (`sudo xcode-select -s
  /Applications/Xcode.app` to select it for signing/notarization).
- **FluidAudio** SPM dep (resolves to 0.15.4+); Parakeet TDT v3 weights download at runtime.
- Local **oMLX** for LLM iteration (OpenAI-compatible): `http://127.0.0.1:11234/v1`, key in
  `~/.omlx/settings.json`. It is a fast local proxy — the **Gemini 2.5 Flash** floor still wants
  a real pass before shipping LLM features.
- Swift 6 **strict concurrency** applies. The proven patterns for AppKit/CGEvent/AX code are
  `nonisolated(unsafe)`, `@MainActor`, `MainActor.assumeIsolated` — see the shipped adapters in
  `Sources/KeyScribe/Adapters/`.
- **Logging / live observability (read before debugging runtime behavior).** The app logs via
  `os.Logger` under subsystem `com.keyscribe.app` (categories in `Sources/KeyScribe/Log.swift`: `bias`,
  `context`, `models`, `insertion`). **Footgun (2026-06-21): `log show` / `log stream` did NOT
  surface these messages on this machine** — filtered by subsystem *or* `process == "KeyScribe"`, with
  `--info --debug`, they returned zero lines even though the strings were verifiably compiled in
  (`strings KeyScribe.app/Contents/MacOS/KeyScribe`) and the app was running. Don't trust "no log
  output" as "the code path didn't run." The reliable ground-truth method for verifying insertion
  was a **clipboard-marker probe**: `printf MARKER | pbcopy`, dictate, then `pbpaste` — an untouched
  marker + nothing inserted ⇒ AX false-`.success` data loss; marker replaced by the text ⇒ the
  clipboard-fallback path ran; text inserted + marker intact ⇒ paste path (saves/restores clipboard).
  If you need logs, run down *why* unified logging is silent here first; don't assume the stream works.

---

## M0 proven facts (don't re-derive; build on these)

All retired via throwaway de-risk spikes (kept local, **untracked** — not in the repo). The
load-bearing results were promoted here; this section is now the record, not a pointer:

- **STT (Parakeet/FluidAudio):** reload-from-cache ~0.13s, transcribe 74–90ms, resident
  ~27–38MB on synth speech. Eviction is nearly free. Proven API:
  ```swift
  import FluidAudio
  let models = try await AsrModels.downloadAndLoad(version: .v3)
  let manager = AsrManager(config: .default)
  try await manager.loadModels(models)
  var decoderState = try TdtDecoderState()
  let result = try await manager.transcribe(url, decoderState: &decoderState)  // result.text
  ```
- **Insertion:** **paste is primary** — it lands across Electron/Chromium/native and undoes in a
  single ⌘Z. AX-insert/type are unreliable (secondary only).
- **Hotkey:** Fn/Globe (keyCode 63, secondaryFn mask `0x800000`) and right-Option (kc 61, mask
  `0x40`; left-Option is kc 58, mask `0x20`) both capturable & distinguishable via CGEventTap.
  Default Fn/Globe hold-or-tap; right-Option as alternative.
- **Context:** frontmost bundle id always available; **⌘C→pasteboard is the universal selection
  capture**; **browser URL via AppleScript/Apple Events, NOT AX** (AX returns nil on Chromium).
  Footgun: synthesized ⌘C has a settle-time race (once dropped a leading "I" → `"slamic…"`) — wait
  for the pasteboard changeCount to bump (or retry) before reading the selection.
- **Permissions = 3 TCC categories:** Accessibility (post ⌘V/⌘C + AX reads), Input Monitoring
  (the event tap), Automation (browser URL via AppleScript — request only when a mode opts into
  URL context).
- **Token-fencing:** `⟦SN:…⟧` nonce tokens survive LLM rewrite (local proxy). Final sentinel +
  Gemini 2.5 Flash adversarial pass deferred to M5/M6.

Carried forward into milestones (not gates): real-voice/noisy STT quality + latency budgets
(M1), press-style timing (M1), per-engine recognition bias (M1/M2), Gemini Flash token pass (M6).

---

## Current state (built through M6, verified live)

**The whole M1–M6 pipeline works end-to-end in the real app** (verified interactively): local
dictation → modes (Phase-A app routing + Phase-B trigger-phrase routing + per-mode trigger keys) →
replacements / live edits → optional **BYOK rewrite** (verified live via local oMLX) → **redaction
wedge** (secrets tokenized before the cloud call, restored locally — proof-logged) → atomic insert.
Plus **edit-in-place** (voice-edit a selection). **Clean build, all tests pass.**

For the live frontier and exactly what's done vs deferred, read **`docs/roadmap.md`** (per-milestone
checkboxes) and **`docs/session-status.md`** (what's verified live + the running fix log). Don't
trust this paragraph over those — they're updated each session.

**STT engines (7, all run live with download+install verified in-app, 2026-06-21):** Parakeet TDT v3,
Parakeet TDT-CTC 110M, Whisper, Apple, **Qwen3-ASR 0.6B**, **Qwen3-ASR 1.7B**, **Moonshine Base (EN)**.
Six bias-capable; Moonshine is bias-exempt (`supportsRecognitionBias = false`, badged). Engines are now
wired through a single **`EngineRegistry`** descriptor list (catalog ↔ constructor) that the provider,
download path, install reconcile/delete, and the benchmark all derive from — adding an engine is one
descriptor + one catalog entry. `load(progress:)` is on the `SpeechEngine` protocol; each engine owns
its install footprint (`installDirNames` / `installState`); audio decode is shared (`AudioDecoder`).

A dev **STT benchmark** (`KeyScribe --benchmark <dir> [--engines …]`, runner + pure scoring in
KeyScribeKit) measures WER (biased vs unbiased) / term recall / RTF per engine over recorded clips. On a
16-clip real-voice corpus: **Qwen3-ASR 1.7B wins** (0.8% WER biased, 100% term recall), 0.6B the
speed/accuracy sweet spot (1.5%, fastest); bias is decisive (Moonshine, bias-less, ~15%). NVIDIA
Canary-Qwen was evaluated and **deliberately dropped** (a CoreML conversion now exists on HF if revisited).

**Settings UI (built, uncommitted):** the Settings window is now a 7-pane `NavigationSplitView`
(General · Speech Models · Vocabulary · AI Services · Modes · Permissions · Advanced). The previously
deferred editors all ship — **Modes** (master-detail mode editor), **AI Services** (BYOK connections,
keys in Keychain), and **Vocabulary** (global Dictionary + Replacements). The **global dictation
hotkey is gone**: each mode owns its `trigger_keys` (with per-key `tap_threshold_ms`), and the menu's
**Dictate with** submenu picks the mode for the next dictation only. The HUD offers an explicit
**Insert local transcript** escape hatch during a cloud rewrite.

**What remains:** the standalone correction-panel shortcut (the History detail's Add to Dictionary /
Create Replacement is the current correction surface), the two **Settings-editor follow-ups**
(per-keystroke writes → explicit Save; default-mode deletion guard — see session-status), and the
rest of **M7** (notarization + Sparkle updates, progressive-disclosure / accessibility polish; GPLv3
`LICENSE`, `THIRD-PARTY-NOTICES.md`, and the expanded notices screen are done). See session-status for
the live frontier.

> **Forked / pinned STT deps (2026-06-21):** three forks + one pinned binary dep, each with a tracked
> upstream-PR TODO in session-status to eventually drop the pin — **deferred to distant future** (the
> pins work live and cost nothing day-to-day; filing the PRs is not near-term work):
> - **WhisperKit** → **`rsperko/argmax-oss-swift` @ `7cc6ea2`** (upstream **v1.0.0**): one-line
>   `!isPrefill` fix for the empty-output-with-`promptTokens` bug (#372) that breaks Whisper bias in
>   every stock release. Depending on just the `WhisperKit` product keeps Vapor/openapi out of
>   resolution (gated behind `BUILD_ALL`).
> - **FluidAudio** → **`rsperko/FluidAudio` @ `b703677`** (upstream **0.15.4**): adds an
>   `enableSpotterRescue` toggle to `ctcTokenRescore` so the weaker `ctc110m` can skip the acoustic-only
>   rescue pass (which false-fired, e.g. "I'm"→"KeyScribe"). Parakeet bias is **CTC-WS** (NeMo
>   constrained-CTC keyword spotting), not the old removed blind post-STT rescorer.
> - **speech-swift (Qwen3-ASR)** → **`rsperko/speech-swift` @ `96273cd`** (upstream `soniqo/speech-swift`,
>   package `Qwen3Speech`): the fork only gates the `AsrBenchmark` (argmaxinc/WhisperKit) and
>   `AudioServer` (hummingbird) targets/deps behind `BUILD_ALL` — needed because stock `speech-swift`
>   pulls `argmaxinc/WhisperKit`, which collides with our WhisperKit fork ("multiple similar targets
>   ArgmaxCore…"). Qwen3-ASR bias is **native** (`Qwen3DecodingOptions.context`), so no source patch is
>   needed — only the dependency-graph gating. We consume only the `Qwen3ASR` product.
> - **Moonshine** → **`moonshine-ai/moonshine-swift` @ `0fb16cc`** (no fork): ONNX Runtime ships as a
>   prebuilt `Moonshine.xcframework` binaryTarget. Moonshine has **no on-device bias** path, so it ships
>   `supportsRecognitionBias = false` (badged "No dictionary bias" in Settings).
>
> **MLX metallib is a hard runtime requirement, not an optimization.** Qwen3-ASR (MLX) crashes
> ("Failed to load the default metallib") without `mlx.metallib` beside the executable. `make-app.sh`
> builds it from the speech-swift checkout's kernels and bundles+signs it into the `.app`; the **Metal
> Toolchain** (`xcodebuild -downloadComponent MetalToolchain`) is a build-time prereq.

**Established build setup:** top-level SwiftPM (`Package.swift`, `Sources/KeyScribeKit` pure +
`Sources/KeyScribe` app + `Tests/KeyScribeKitTests` pure-logic tests + `Tests/KeyScribeTests` app-target
tests via `@testable import KeyScribe`, used when an OS-edge orchestrator needs a regression test
through DI seams), bundled into an LSUIElement `.app` by
`./make-app.sh` (signs with a stable self-signed cert for persistent TCC if one is present —
contributors create a **`KeyScribe Local`** cert, the maintainer's **`SnagShot Dev`** also
auto-detects; else ad-hoc. Identity override: `CODESIGN_IDENTITY` / `KEYSCRIBE_SIGN_ID`. Full
from-source build, prerequisites, and signing steps live in **`BUILD.md`**. A `Developer ID` cert
for notarization is an M7 need; `KeyScribe.entitlements` is the tracked hardened-runtime entitlements
file, **dormant** until M7 — `make-app.sh` doesn't pass it yet. The bundle's `Info.plist` is a tracked
source file at `Resources/Info.plist`; `make-app.sh` stamps `CFBundleShortVersionString` from the
latest git tag and `CFBundleVersion` from the commit count, so don't hand-edit version keys).
Config lives under `~/Library/Application Support/KeyScribe/`,
loaded once into `ConfigCache` and invalidated by an FSEvents watcher (no per-dictation I/O).

**Keep building pure logic test-first** (`principles.md` §9): the OS-free core in `KeyScribeKit`
(pipeline, mode resolution, tokenization, gate, regex via `RegexCache`, config models) is unit-
tested; OS edges (AVAudioEngine, paste, CGEvent hotkeys, SwiftUI) are thin adapters in
`Sources/KeyScribe`. The UI work that remains is the part that needs an interactive session to verify.

### `dt` / git note
This repo has a **normal git origin once pushed** (it is *not* shop/world) — plain `git`/`gh`
apply, not the `dt` shim. No commits without explicit user instruction.

---

## Working discipline

- **No commits, branches pushed, or PRs without explicit user instruction.** No AI self-
  references anywhere in repo content (commit messages, code, docs).
- **ZERO code comments** unless explicitly requested — self-documenting names and structure.
- **TDD red→green** for pure logic; thin adapters + integration tests for OS edges.
- **File-based storage, no SQLite** — everything lives under `~/Library/Application
  Support/KeyScribe/`: config as TOML (modes/connections/dictionary/replacements), fragments as
  markdown+YAML, history as JSONL-per-day, and downloaded STT weights consolidated in `models/`
  (`config_schema.md` has the layout). Every persisted *config* file carries `schema_version` and
  migrates forward (`design.md` §5.1); `models/` is runtime-downloaded, never committed.
- **Reuse the UI vocabulary** in `ui_components.md`; never overstate privacy (no "secure/safe/
  private" for best-effort redaction — say what actually happens).
- When a design choice leans on a principle, note it inline as the docs do.
