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

- **The recording HUD is key ⟺ the HUD is visible and cancellable** (`HUDState.holdsKeyFocus`).
  Synthesized ⌘C/⌘V/Return go to the key window, so the
  HUD (`KeyablePanel`) must relinquish key focus before any selection-capture ⌘C or paste ⌘V —
  `HUDController.relinquishKeyFocus()` runs when a take begins acting (an insert's `TakeLease.beginActing`,
  an agent delivery, a voice command's first act), in `rewriteSelection`, in `pasteLast`, and on every
  non-recording `render`. Take code reaches the HUD only through `HUDChannel`, never `HUDPresenting` directly.
  **Arming is deliberately outside this**: it shows no HUD (`ui_design.md` §5's timing contract — a
  panel before admission invites speech that is discarded), so the panel is NOT key while the mic
  comes up and ESC does not reach us there. That is not a gap: `handleCommit`'s `.arming` case means
  the TRIGGER cancels an arming dictation — release for a hold trigger, second tap for a latched one.
  It also means a wedged bring-up can no longer swallow the user's typing, which it did when arming
  held key focus. Do not add an arming HUD to "restore" ESC.
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
  flavor blocks main for its whole render. `beginScratchPaste` threads ONE deadline through every
  stabilize capture (`maxSnapshotStabilizeAttempts` retries plus the first), else that stall multiplies
  by the attempt count. Tests pin both halves
  (`lazyFlavorsThatBlowTheBudgetFallBackToPlainText`, `aSlowFlavorOutlastingTheBudgetStillRendersToCompletion`)
  plus a data-provider probe asserting the render ran on the main thread. Two traps when touching this:
  nested types do **NOT** inherit the enclosing `@MainActor` (`PasteboardSnapshot` sits inside `@MainActor
  enum TextInserter` yet its members are nonisolated unless annotated — `capture`/`restore`/`restoreFull` each
  say so explicitly); and a `SlowDataProvider`-style test now sleeps **on the main actor**, so keep such
  delays just over the budget (~0.3 s, never seconds) or it starves every other `@MainActor` test in the suite.
- **A take snapshots the clipboard while the engine transcribes, not between the transcript and ⌘V.**
  `TextInserter.prefetchSnapshot` is an ordinary synchronous main-actor `capture`, run from a main-actor
  task while the take is suspended on the engine, so the render costs no time after the transcript unless
  inference finishes first. It drains a pending restore before it captures, for the same reason
  `beginScratchPaste` does. `beginScratchPaste` uses a prefetched snapshot once, only for the same
  pasteboard and only when `changeCount` has not moved; anything else is a fresh capture. The take awaits
  its prefetch before anything can paste, a prefetch for a take that already ended does nothing, and every
  terminal discards the slot.
