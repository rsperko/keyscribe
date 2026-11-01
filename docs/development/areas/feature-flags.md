# Feature flags

Read before adding, reading, or retiring a feature flag.

## How flags work

Ship in-development features behind an opt-in toggle, exercise them, then roll them out by deleting
the flag. The single source of truth is the **`Feature`** type (`Sources/KeyScribeKit/Features.swift`) —
a struct whose `static let` catalog (listed in `allCases`) is the set of flags;
state lives in the global `settings.toml` `[features]` table as **deviations only** — it stores just
the ids the user turned on, so an absent (or unknown, or pruned) id means **off**. Flags are strictly
opt-in (no per-flag default-on) and appear in every build under **Settings → Maintenance → Experimental
features** (the section hides itself when there are no flags).

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
  append it to `allCases`. The Maintenance toggle renders automatically; no UI code to touch.
- **Roll out / retire:** delete the `static let` and its `allCases` entry, and make the gate unconditional
  (or delete the dead branch). A stale id left in a user's `settings.toml` is ignored and dropped on the next write.

`allCases` may be empty — that is the normal state once every flag has been rolled out, not a bug.
`Feature` is a **struct** with a
`static let` catalog rather than an enum precisely so that empty state does not read to the compiler as
unreachable code, and so the Experimental features section can hide itself when `allCases` is empty. When you add a flag,
also add per-flag tests — default-off fallback, override persistence, and off-elision.

## Rollout debt

**`consumptionDrivenRestore` carries a rollout debt — do not delete the flag until it is paid.** The
flag restores the scratch as soon as the target has actually read the lazily-published pasteboard,
instead of waiting out `[insertion] clipboard_restore_ms`. Four things block its rollout, and the
in-process tests can observe none of them:

1. **The target's ⌘V waits on KeyScribe's main run loop.** A cross-process read of the lazy flavor is
   fulfilled on the owner's main thread via its run loop — measured, the owner's main thread blocked
   3 s made the reader's `string(forType:)` block 2 s — so the target's paste is served only after the
   post-insert cue, HUD render, and record-keeping, and a wedged main thread here stalls the *target*
   app. Measure target-side paste latency on vs off (the `held=` log cannot show it) and decide whether
   the coupling is acceptable at all. A yield after `postKey` is untested.
2. **Only the first read is ever observed, and nothing identifies the reader.** After fulfilment the
   pasteboard caches the string and releases the provider. The write and the ⌘V post are microseconds
   apart, so a clipboard manager that ignores the concealed marker and reads the string lands after the
   ⌘V mark and is taken for the target's paste; restore then fires early and a slow target pastes the
   old clipboard. Honoring managers inspect types only, which never fires the provider — so test with a
   manager that does **not** honor `org.nspasteboard.ConcealedType`.
3. **The "Chromium reads more than once" claim is second-hand.** Measure the 100 ms grace against a
   real Chrome/Electron paste before trusting it.
4. **A cross-process regression test is owed.** Shape: compile a small reader with `swiftc` against a
   named pasteboard, spawn it, and assert both the served text and the restore timing.

Then run the clipboard-marker probe (`printf MARKER | pbcopy`, dictate, ⌘V) with the flag ON in
TextEdit, Slack, VS Code, Chrome, Terminal, and Word, and with a clipboard manager running: each must
paste the dictation, and the immediate ⌘V must paste `MARKER`.
