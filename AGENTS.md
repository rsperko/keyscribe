# KeyScribe — Agent Orientation

KeyScribe is a **privacy-first, local-first voice dictation app for macOS** (Superwhisper/
MacWhisper class). Speech recognition is **always on-device**; an **optional, user-keyed (BYOK)
LLM rewrite** is the only thing that may ever leave the machine, and only after sensitive spans
are tokenized out. Native Swift/SwiftUI menu-bar app. Open source, GPLv3.

This file is the entry point and stays short on purpose: it holds the rules that apply to every
change. Rules for one area live in that area's guide under `docs/development/areas/` — open the guide
before you edit code in its area.

---

## Hard invariants (never violate)

- **STT is always on-device. There is no cloud STT, ever.**
- **Exactly one STT engine is active globally** (user-selected). Multiple named *LLMs* are
  allowed; the STT engine is singular. Resolve it through one provider (seam for per-mode later,
  not built — YAGNI).
- **The only outbound network calls that carry content are explicit BYOK LLM calls**, each over a redacted
  payload and each to a connection the user chose for that purpose: a mode's rewrite of the transcript, and,
  when the user turns on the Coding agent spoken updates and chooses a service, the summary of an agent's final reply to the user's
  own dictation and the description of a prompt that turn waits on, from the prompt's title, the tool call it seems to
  be about, and the agent's last words (`SpokenResultOutput`). One content-free exception: when the **Phase-A resolved mode is wired to a BYOK
  connection** — and only after the secure-aware snapshot has confirmed the field is not a password
  field — a **bodyless, auth-less HEAD preconnect** to that connection's host may fire during recording
  to warm the TLS connection (`HTTPLLMClient.preconnect`, gated by `DictationController.maybePreconnect`
  on the resolved mode AND the adopted snapshot). It carries no user content and touches only the host
  that mode's connection points at. The rewrite may not ultimately fire (cancel, no speech, a
  whole-utterance replacement, or a Phase-B route to a local mode); the preconnect stays content-free
  regardless, and a focused secure field neuters the mode so none fires there.
- **No telemetry, no analytics.** Speech, transcripts, and usage are never collected.
- **Agent integrations must have minimal impact, whether KeyScribe is running or not.** Normal
  agent actions never wait on KeyScribe or connector I/O. Background work stays bounded; lost
  connections never replay stale actions. Integrations must be easy to disable and uninstall
  without deleting user data (`docs/development/principles.md` §10).
- **Dictation is batch (commit-on-release) and inserts atomically** — one ⌘Z undoes the whole
  dictation.
- **No app/mode identity in source.** No `if app == "Slack"`, no per-app presets. A Mode is a
  named bag of config a generic pipeline executes (`docs/development/principles.md` §2). Adding a mode = adding
  data, never code.
- **Public docs are for users first, and docs state rules, never tallies.** Implementation detail
  stays out of the user docs, and no doc counts or lists code entities — name the source of truth.
  Measurements stay, anchored in time. Full rules: `docs/development/areas/writing-docs.md`.

---

## Pipeline and privacy footguns (these silently corrupt or leak)

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
  short-circuited in `DictationController.produceDictationText` (through `TakeText.bare`). Only the rule's own text is frozen: the
  words it **captured** (`$1`) still pass through the later text stages (numbers, the dictionary), which
  `Pipeline.forward` runs on `PipelineContext.bareSegments`; a split that does not reproduce the regex
  engine's output keeps the whole output frozen. Regex/literal replacements both match
  **case-insensitively** by default (STT output is engine-cased; `(?-i)` opts back in). See
  `docs/reference/config_schema.md` *Replacement matching & output*.
- **Credential material is never persisted in config.** Saved API keys live in Keychain and TOML
  stores only `key_ref`; command-generated bearer tokens are in-memory only. `token_command` stores
  the command to run, not the token material itself (`docs/reference/config_schema.md`).
- **Edit-in-place is a capability, not a special mode** — any mode can be `source=selection` /
  `output=replace_selection`; ⌘C→pasteboard is the selection capture, AX is a native-only bonus
  (`docs/development/design.md` §4.3).

---

## Area guides — read the guide before editing its area

Each guide holds the full rules, measurements, and rationale for its area. The headline rules below
are the ones that must never break; the guide explains why and what else applies.

- **Audio capture** → `docs/development/areas/audio-capture.md` (AUHAL unit, realtime callback, ring
  and writer thread, bring-up and readiness, tail drain, idle warm-up).
  - Capture pins the device on its own unit and never changes the macOS default input — no
    `setSystemDefaultInput` on the capture path.
  - Commit drains the tail through `finishDraining()`; `stop()` discards audio and is for cancel only.
  - The realtime IO callback takes no lock, allocates nothing, makes no syscall, and resumes no task.
  - HAL bring-up and teardown run off the main thread on the serial control queue, under the watchdog.
  - Validate capture changes with `KeyScribe --capture-probe`; a capture defect is inaudible.
- **Hotkeys, triggers, permissions** → `docs/development/areas/hotkeys-and-permissions.md` (modifier
  matcher, Carbon chords, event taps, keyboard layouts, conflicts and shadowing, TCC).
  - Never call `tapCreate` before `AXIsProcessTrusted()`; never request Input Monitoring.
  - The modifier matcher is an exact match of normalized flags and must stay in lockstep with
    `ModifierKeySet.canEngageTogether`.
  - A chord's base key is a character resolved through the live layout's shortcut table, never a key code.
  - Every hotkey rebuild goes through `AppDelegate.rebuildHotkeyMonitor`.
  - The mouse-button tap is the one consuming tap and never runs on the main run loop.
- **Insertion, pasteboard, HUD focus** → `docs/development/areas/insertion-and-hud.md`.
  - Paste is the primary insertion path; AX insert is a verified secondary.
  - The recording HUD is key only while visible and cancellable; relinquish key focus before any
    synthesized ⌘C or ⌘V.
  - `PasteboardSnapshot.capture` stays synchronous and `@MainActor`. `runWithDeadline` and
    `runWithBudget` are never used for AppKit work.
- **Speech-to-text engines** → `docs/development/areas/stt-engines.md` (catalog, engine adapters,
  no-speech gate, empty-transcript recovery, recognition bias, streaming).
  - Sweep every new model, and every dependency bump, over silence in batch and in streaming. The
    audio-side gate fails open.
  - A bias-capable engine passes the distractor false-fire sweep before bias ships enabled.
  - Do not raise `minSpeechChunks` without the measurements the guide names.
- **Dependencies** → `docs/development/areas/dependencies.md` (forks, pins, upstream mutation, MLX shaders).
  - Never bump WhisperKit below 1.1.0. Keep the Silero VAD artifact pinned. The speech-swift fork is
    still required.
  - A green warm build proves nothing about a fresh checkout: run `make check-deps`.
  - A FluidAudio bump re-checks the spoken result voice: the speaker grades behind `SpokenVoices.all`,
    that none of its error-level logs carry the text it speaks or transcribes, and that loading an installed
    voice downloads nothing.
- **Build, variants, release** → `docs/development/areas/build-and-release.md`.
  - Apps build through `App/project.yml`; a bare `swift build` has no MLX shader library.
  - `make preflight` must pass before anything is published. A release build is a background job.
- **Config storage and migrations** → `docs/development/areas/config-and-storage.md`.
  - Every config file carries `schema_version`; a migration is an idempotent transform run on every read.
  - Keep `MigrationRunner` and the `migrations:` hook even with no in-tree steps — downstream uses them.
- **Voice commands and coding agents** → `docs/development/areas/voice-commands.md` (resolution,
  execution, choices, previews, their settings, and the coding-agent bridge).
  - Check `stillWanted` immediately before every side effect, not once at the start.
  - Missing, unreadable, timed out, and uncertain stay distinct states; none of them means empty or success.
  - An unresolved target or recipient asks; it never falls through to the current or first one. A tie
    takes a predictable order (a recipient tie, the first name alphabetically) and asks only when no such
    order exists or a wrong guess would run the wrong action (different apps, places, or windows, or tabs
    in different browsers, tied for a switch are offered as a choice).
  - Previews and uniqueness checks call the same matching function execution uses.
- **Feature flags** → `docs/development/areas/feature-flags.md`.
  - Flags are `static let`s on `Feature`, opt-in only, read through `settings.features.isEnabled`.
  - Do not delete `consumptionDrivenRestore` until its rollout debt in the guide is paid.

**`DictationController` and `AppDelegate` orchestrate every area**, so no single guide covers them. The
controller owns the state machine, the take's lease, and the diagnostics record; the per-take work lives in
`Sources/KeyScribe/Take/`. Route by the function or component you are changing:

- `beginCapture`, `handleStart`, `handleCommit`, `TakeRecorder` → audio capture, plus insertion and HUD for
  the HUD flip.
- `presenceReading`, `finalizeStreamingIfActive`, `Transcriber`, `EngineKeeper` → speech-to-text engines.
- `finishInsertion`, `InsertOutput`, `HUDChannel`, `rewriteSelection`, `pasteLast` → insertion, pasteboard,
  HUD focus.
- `VoiceCommandOutput`, `AgentOutput` → voice commands and coding agents.
- `probeCandidates`, `PressResolver`, and in `AppDelegate` `rebuildHotkeyMonitor`, `claimableModes`,
  `shadowedHotkeyIds`, `launchAttention` → hotkeys, triggers, permissions.
- `maybePreconnect`, `produceDictationText`, `TakeText`, `TakeRewrite`, `SelectionText` → the hard
  invariants and pipeline footguns above.

---

## Specs — read the section for your change, not the whole tree

`docs/development/principles.md` is short and governs every decision; read it once. The other specs
are large references: search them for the section you need rather than reading them end to end.

| Changing… | Read |
|---|---|
| Pipeline stages, tokenization, the LLM gate | `docs/development/design.md` §4.2 (§4.2.1 ordering is load-bearing) |
| Modes, routing, context, insertion, storage | `docs/development/design.md` §4.3, §4.4, §4.5, §5 |
| Any user-facing surface | `docs/development/ui_design.md` — normative; implementation does not override it (first run §2, HUD §5, menu §6, Settings §7, History §8) |
| Widgets, badges, status words | `docs/development/ui_components.md` — reuse its vocabulary; never invent a competing badge or status word |
| On-disk formats, starter modes | `docs/reference/config_schema.md` |
| The LLM rewrite prompt | `docs/development/prompt_design.md` |
| What is built and what is not | `docs/development/roadmap.md` |
| Release testing | `docs/development/release_testing.md` (the mandatory release gate) |
| App icon, competitors | `docs/development/icon_design.md`, `docs/development/competitors.md` |

Everything under `docs/reference/` is normative when you touch its area.

---

## Repo layout

```
keyscribe/
  AGENTS.md            # this file (CLAUDE.md is just `@AGENTS.md`)
  Package.swift        # SwiftPM: the library products + KeyScribe executable + tests — read it for the targets
  Sources/
    KeyScribeKit/        # pure, OS-free logic (TDD red→green)
    KeyScribe/           # the menu-bar app: adapters + SwiftUI/AppKit — target/module KeyScribeApp
      Take/              #   per-take components DictationController coordinates (outputs, recorder, engines)
    KeyScribeMain/       # main.swift only: the thin executable over KeyScribeApp
                         #   (further targets exist — see Package.swift)
  Tests/KeyScribeKitTests/ # pure-logic unit tests
  Tests/KeyScribeTests/    # app-target tests (@testable import KeyScribeApp) — OS-edge orchestration via DI seams
  Makefile             # task front door — `make help` lists build/run/release/test/setup/…
  App/                 # the shared Xcode app definition: template.yml (the target template a downstream
                       #   include:s) + project.yml (this repo's targets), plus signing/export config; the
                       #   generated KeyScribe.xcodeproj is gitignored
  make-app.sh          # → KeyScribeDev.app (dev variant, default; self-signed — see BUILD.md)
  release.sh           # → notarized production KeyScribe.app + DMG (./release.sh patch|minor|major)
  scripts/             # dev helpers behind the make targets — `make help` lists them; prepare-xcode-project.sh
                       #   and collect-licenses.sh belong to the build itself. Cite a script by its make target.
  docs/                # user docs, plus development/reference specs; development/areas/ holds the
                       #   per-area guides listed under "Area guides"
  corpus/              # recorded-speech corpus + replay harnesses (committed kit; *.wav + results.json
                       #   gitignored — your own voice). One folder per sub-corpus = a manifest + flat
                       #   <id>.wav (the runner convention); ls corpus/ for the current set, each with
                       #   its own README. Runners: KeyScribe --benchmark <dir> (engine WER, ranked by
                       #   compare.sh) and --commands-check <dir> (spoken-command regression).
                       #   Record: bash corpus/record.sh [--commands].
```

---

## Toolchain

- macOS 26.x, arm64, **Swift 6.3+**, **Xcode.app installed** (`sudo xcode-select -s
  /Applications/Xcode.app`), the **Metal Toolchain**, and **XcodeGen** (`brew install xcodegen`) — the
  app is built through `App/project.yml`, never a bare `swift build`.
- **FluidAudio** SPM dep; Parakeet weights download at runtime.
- Local **oMLX** for LLM iteration (OpenAI-compatible): `http://127.0.0.1:11234/v1`, key in
  `~/.omlx/settings.json`. The **Gemini 2.5 Flash** floor still wants a real pass before shipping
  LLM features.
- Swift 6 **strict concurrency** applies. The patterns for AppKit/CGEvent/AX code are
  `nonisolated(unsafe)`, `@MainActor`, `MainActor.assumeIsolated` — see the adapters in
  `Sources/KeyScribe/Adapters/`.
- **Logging:** `os.Logger` under subsystem `com.keyscribe.app` (categories are declared in
  `Sources/KeyScribe/Log.swift` — read the file for the current set). Footgun: `log show` /
  `log stream` do **not** reliably surface these on this machine even when the strings are compiled
  in — don't trust "no log output" as "the code path didn't run." The reliable ground-truth for
  verifying insertion is a **clipboard-marker probe**: `printf MARKER | pbcopy`, dictate, then
  `pbpaste` — untouched marker + nothing inserted ⇒ AX false-`.success` data loss; marker replaced ⇒
  the clipboard-fallback path ran; text inserted + marker intact ⇒ the paste path (saves/restores).

---

## Platform facts (build on these; don't re-derive)

- **Token-fencing:** `⟦SN:…⟧` nonce tokens survive LLM rewrite (verified against the Gemini 2.5
  Flash floor, 24/24 across hard rewrite shapes).
- Engine, capture, hotkey, insertion, and permission facts live in their area guides above.
- This repo has a **normal git origin** (it is *not* shop/world) — plain `git`/`gh` apply.

---

## Working discipline

- **No commits, branches pushed, or PRs without explicit user instruction.** No AI self-references
  anywhere in repo content (commit messages, code, docs).
- **ZERO code comments** unless explicitly requested — self-documenting names and structure.
- **TDD red→green** for pure logic; thin adapters + integration tests for OS edges. Keep building
  the OS-free core in `KeyScribeKit` (pipeline, mode resolution, tokenization, gate, regex via
  `RegexCache`, config models) test-first; OS edges (AUHAL capture, paste, CGEvent hotkeys, SwiftUI)
  are thin adapters in `Sources/KeyScribe`.
- **Iterate on `KeyScribeKit` with `make test-kit`** (`FILTER=<regex>` narrows). It builds Kit and its tests
  in a package without the engine stack, so a Kit edit never recompiles the app or links the speech
  engines. It skips the app tests: run `make test` before calling a change done.
- **A fix covers every site of the pattern.** Before reporting a review finding fixed, grep for the same
  pattern elsewhere and fix the siblings too, and make its regression test reproduce the failing window
  itself (no reload before the retry, no loosened timing, no fixture that sidesteps the bug).
- **A behavior or name change updates every place that describes it.** Grep the user docs (README, FAQ,
  PRIVACY), `docs/reference/`, `docs/development/ui_design.md`, and in-app strings for the old name and
  for any promise about the behavior.
- **Grep-able invariants are pinned by `SourceInvariantsTests`** (Kit tests), each with an allowlist of the
  files allowed to break it. A failure names the rule; move the code behind the sanctioned seam rather
  than widen the allowlist.
- **File-based storage, no SQLite** — everything under `~/Library/Application Support/KeyScribe/`.
- **Reuse the UI vocabulary** in `docs/development/ui_components.md`; never overstate privacy (no "secure/safe/
  private" for best-effort redaction — say what actually happens).
- **Every HUD draw goes through `HUDChannel.present`** — it keeps a pending voice-command question
  readable. **Every event that stops voice-command work goes through `VoiceCommandOutput.stop`** — its counter
  is what both the spoken and clicked paths re-check. No direct `hud?.render`, no stop event that cancels by hand.
- **Never hardcode the product name in user-facing copy — use `Branding.appName`** (resolves from the
  running bundle: "KeyScribe" prod, "KeyScribeDev" dev, the bundle name for a `custom` rebrand). The
  literal "KeyScribe" lives in exactly one place, `AppVariant.production.displayName`; everything else
  interpolates `\(Branding.appName)`. This is the white-label seam (a downstream app target on the
  `App/project.yml` template sets its own `PRODUCT_NAME` / `PRODUCT_BUNDLE_IDENTIFIER`, which
  `Resources/Info.plist` substitutes); a hardcoded name breaks a downstream rebrand and shows the wrong
  name in the dev build.
- When a design choice leans on a principle, note it inline as the docs do.
