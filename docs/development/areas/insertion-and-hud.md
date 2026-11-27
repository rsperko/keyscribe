# Insertion, pasteboard, and HUD focus

Read before changing text insertion, pasteboard capture or restore, selection capture, or which window holds key focus during a dictation.

## Platform facts

- **Insertion:** **paste is primary** — it lands across Electron/Chromium/native and undoes in a
  single ⌘Z. AX-insert/type are unreliable (secondary only; AX is verified by reading the field
  value back, else falls back to paste).
- **Context:** frontmost bundle id always available; **⌘C→pasteboard is the universal selection
  capture**; **browser URL via AppleScript/Apple Events, NOT AX** (AX returns nil on Chromium).
  Footgun: synthesized ⌘C has a settle-time race — wait for the pasteboard changeCount to bump (or
  retry) before reading the selection.

## Invariants

- **The recording HUD is key ⟺ the HUD is visible and cancellable** (`HUDState.holdsKeyFocus`), except
  during a take started by a double-tap trigger, which leaves focus with the app and claims Escape as a
  Carbon hot key instead (`HUDController.takesKeyFocus`) — and takes focus anyway if that claim is refused.
  Synthesized ⌘C/⌘V/Return go to the key window, so the
  HUD (`HUDPanel`) must relinquish key focus before any selection-capture ⌘C or paste ⌘V —
  `HUDController.relinquishKeyFocus()` runs when a take begins acting (an insert's `TakeLease.beginActing`,
  an agent delivery, a voice command's first act), in `runOnSelection`, in `pasteLast`, and on every
  non-recording `render`. Take code reaches the HUD only through `HUDChannel`, never `HUDPresenting` directly.
  **Arming is deliberately outside this**: it shows no HUD (`ui_design.md` §5's timing contract — a
  panel before the mic is live invites speech it cannot record), so the panel is NOT key while the mic
  comes up and ESC does not reach us there. That is not a gap: `handleCommit`'s `.arming` case means
  the TRIGGER cancels an arming dictation — release for a hold trigger, second tap for a latched one.
  It also means a wedged bring-up can no longer swallow the user's typing, which it did when arming
  held key focus. Do not add an arming HUD to "restore" ESC.
  `CorrectionPanelController` solves the same problem by capturing `previousApp`
  + selection first, then orderOut → activate → wait → paste.
- **A clipboard snapshot is read in a child process.** Another app
  renders a promised flavor (a large image, typically) only when it is read, and macOS offers no bounded or
  cancellable read, so a read in the app blocks the main thread, and with it the HUD and every hotkey, for the
  whole render. `PasteboardSnapshot.read` runs `PasteboardReader`: a copy of the app binary started with
  `--read-pasteboard`, which reads the named pasteboard, sends its `changeCount` and plain text first and then
  every flavor, and is killed at the deadline (`readBudgetSeconds`, 1 s: it overlaps transcription for a take;
  a paste whose prefetch got nothing reads once more, so a declined paste waits at most two budgets). A read cut short, or one over `maxSnapshotBytes`, keeps
  the plain text. A read that got nothing in time (the owner is slow to render even its plain text) returns
  nil and the paste is declined, keeping the user's clipboard; the words stay for Paste last dictation. Even a
  plain-text-only clipboard goes to the child: its types say nothing about whether its text is already rendered
  (`aSlowPlainTextOnlyClipboardIsReadInTheChildToo`). A full read through the child took 0.02 s, a 4 MB PNG
  included, in a Release dev build (measured 2026-11-27; the first launch right after the build took 0.87 s). A
  child that cannot start, or exits without an answer, falls back to the in-process read below.
  `DevCLI.handleFlags` answers the flag and sets the helper, so a host that never calls it keeps the in-process
  read. The child also ends itself after `childLifetimeSeconds` in case the app is gone. Tests:
  `aSlowImageInAnotherAppIsRenderedForTheChild` (a JXA script in its own process is the slow source; a
  slow provider in the test process would render on the test's own main thread),
  `aSourceSlowerThanTheDeadlineKeepsOnlyItsPlainText`, `aSlowPlainTextGivesNothingToRestore`. Other clipboard
  reads (the Agent mode's spoken "clipboard", `currentClipboardText`) still read in the app.
- **One clipboard transaction at a time.** `TextInserter.exclusively` serializes every clipboard snapshot: a
  paste holds it from its snapshot through the ⌘V and the registered restore, a selection capture through its
  restore, and a prefetch for its read. The read suspends, so without it a second paste could stage its scratch
  while the first reads, and the first would snapshot that scratch as the user's clipboard and later restore
  dictated text. A transaction waits for a restore still pending to end at its own trigger (the target's read,
  or `restoreMs`) rather than forcing it, since a target that reads the ⌘V late would otherwise get the user's
  clipboard or the next paste's text. A prefetch takes the gate itself, so a paste awaits its prefetch before
  taking the gate, never inside it. Because a paste can now wait (on its prefetch, a pending restore, or a read)
  after the take's target check, it checks again just before the keystroke whenever it waited
  (`TextInserter.targetStillFocused`, set by `InsertOutput` from the same `decideInsertion`). That check
  suspends, so the synchronous checks come after it, with nothing between them and the keystroke: the take
  still wants it, the same app is in front (`frontmostApp`), and the clipboard still holds the scratch (so a
  tool that rewrites every copy can skip a paste in a mode with a paste settle delay; skipping is the safe
  direction). The app starts the reader once at launch (`PasteboardReader.warm`), touching no pasteboard, so the
  first real read does not pay for a cold start. A
  discarded or replaced prefetch is cancelled, so it gives up its place in the gate. A selection capture takes the
  prefetch when it still matches, and leaves the snapshot it restored as the prefetch, stamped with the
  `changeCount` its own restore claimed, so the paste after it reads nothing. Reads that are not snapshots (the
  Agent mode's spoken "clipboard", `currentClipboardText`) still force a pending restore: they run inside the
  synchronous text pipeline. Tests: `aSecondPasteDuringTheFirstsClipboardReadWaitsAndRestoresTheUsersClipboard`,
  `aTargetThatReadsThePasteLateStillGetsThatPastesText`, `anotherAppInFrontAfterTheReadSkipsThePaste`,
  `aPasteThatWaitedOnTheClipboardChecksItsTargetAgainBeforeTheKeystroke`,
  `aCopyLandingWhileTheTargetIsCheckedAgainIsNeitherPastedNorOverwritten`.
- **The in-process read stays synchronous `@MainActor`.** It is the fallback when no helper is set or the child
  cannot start. `NSPasteboard`/`NSPasteboardItem` are main-thread-only: `data(forType:)` on a promised flavor
  drives CFPasteboard's cross-process XPC bridge, and doing that off-main corrupts the CF object graph and
  **PAC-traps** (`EXC_BREAKPOINT` in `__CF_IS_OBJC` ← `_CFXPCCreateXPCObjectFromCFObject`), a shipped crash.
  **`runWithDeadline`/`runWithBudget` are the wrong tool for any AppKit work**: `operation` is `@escaping
  @Sendable`, so it lands on the cooperative pool, and on expiry they only abandon it, so an abandoned render
  kept touching items the main actor then invalidated. With no suspension point a single `capture` is atomic
  against the clipboard; `renderBudgetSeconds` is checked between flavors, so one wedged flavor still blocks
  main for its whole render, which is why the child exists. Nested types do **not** inherit the enclosing
  `@MainActor`, so `capture`/`restore`/`restoreFull` each say so; a `SlowDataProvider`-style test sleeps on the
  main actor, so keep such delays just over the budget (~0.3 s).
- **Only a take that may paste reads the clipboard.** `Mode.mayPaste` decides, from the mode's output and
  insertion method (AX insert counts, since it falls back to paste); any other take reads the clipboard only when
  the user asks for it by voice. The read starts while the engine transcribes, once the press's mode is known
  (`startClipboardPrefetch`), as a task `beginScratchPaste` awaits, so nothing before the paste waits for it:
  routing, a rewrite, help and the Agent path run while it reads. It drains a pending restore before it reads,
  for the same reason `beginScratchPaste` does. The paste uses that snapshot once, only for the same pasteboard
  and only when `changeCount` has not moved; anything else, including a phrase that routes to a pasting mode
  after the transcript, is a fresh read. Every terminal drops the task.
- **A long agent roster lays out only the rows in view.** Once the roster needs a scroll view, its rows are a lazy
  stack, so showing and updating the HUD costs about the same with hundreds of conversations as with a few. As
  measured in a debug build on 2026-11-25, with 400 rows over five takes (show, three updates, transcribing,
  hide): 19 to 40 ms a take, against 160 to 300 ms with every row laid out. The harness that measured it was not
  kept: it only timed the takes, and a HUD that is never put on screen does not scroll, so it could not show
  whether the row in front is scrolled into view. Check that in the running app, with a few hundred rows and the
  conversation in front far down the list.
