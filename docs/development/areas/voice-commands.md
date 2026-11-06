# Voice commands

Read before changing voice-command resolution, execution, choices, previews, or their settings
(`VoiceCommandResolver`, `VoiceCommandSystem`, `VoiceCommandChoice`, `VoiceCommandPreview`, the
Voice Commands settings pane, `VoiceCommandCLI`). A spoken phrase becomes a side effect on another
app — a launch, a focus, a keystroke, a script — so these mistakes reach the user's desktop, and
review keeps finding the same few of them.

## Cancellation and supersession

- **Check `stillWanted` immediately before every side effect** — launch, activate, focus, keystroke,
  script, delivery — not once at the start of resolution. A cancel, timeout, or newer take can land
  during any `await`, and work that resolves after it must not act.
- **A late completion must not overwrite newer state.** When an async result arrives, confirm it still
  belongs to the current request (its id or counter) before it touches the HUD, a pending choice, or an
  editor. Every stop path goes through `VoiceCommandOutput.stop` (AGENTS.md).
- **Previews, trials, and the CLI run without side effects by construction**: they take an explicit
  no-side-effect path, never the live executor with a flag checked late.

## Failure is not absence

- **Keep missing, unreadable, timed out, and uncertain as distinct states end to end.** A browser-tab
  read that times out is not "no matching tab"; a file that fails to decode is not a missing file; an
  unconfirmed action is not a success. Collapsing them turns a transient failure into a wrong action
  or a destructive write.

## Targets

- **Address a target by a stable identity captured when the decision is made, and recheck it right
  before acting.** Never act on a positional index, a PID, or a display name alone — windows, tabs,
  and apps reorder between resolution and execution.
- **An unresolved or tied target holds and asks; it never falls through to the current, first, or
  default target.** Equally close fuzzy matches are a choice for the user, not a tie-break by order.

## One rule, one function

- **Previews, advisories, examples, and uniqueness checks call the same matching function execution
  uses.** A second implementation drifts (word boundaries, case, normalization), and the preview then
  promises something execution does not do.
- **Strip parsed parts out of the original text; never rebuild the remainder.** Re-casing, re-joining,
  or re-normalizing the leftover corrupts content the user dictated (`npm test` must stay `npm test`).

## Coding agents

The coding-agent bridge (`AgentHub`, `AgentBridge`, `AgentHandles`, `AgentRecipient`, `AgentOutbox`,
the terminal routes, the Claude connector) delivers dictated text to another program, so every rule
above applies to it, with these sharpenings:

- **Minimal agent impact is a release requirement** (`docs/development/principles.md` §10).
  Observation hooks never await bridge work or perform I/O. They preserve downstream results,
  errors, cancellation, and other extensions' UI; connector failures must not interrupt agent work.
- **Bound background work across failures and reconnects.** A timed-out request still counts as
  outstanding until it settles. Idle checks, retries, queues, timers, and stored receipts must not
  grow with session age or failure count.
- **Validate connection identity on both sides of the bridge.** Recheck session, connection,
  expiry, and cancellation immediately before acting. Reconnection holds stale dictation for
  review; it never grants old queued commands permission to run again.
- **Removal preserves user data and unrelated agent configuration.** Retire loaded connectors
  without waiting for them, verify uninstall state, and keep partial cleanup safe to retry.
- **An unknown or ambiguous spoken recipient never falls through to the current recipient.** It holds
  and asks, like any unresolved target.
- **Cancel withdraws the request itself, not just its HUD.** A message the user cancelled must not
  still send, and a cancelled message must not stay visible as if it will.
- **A receipt timeout is "unknown", not "failed" or "gone".** A request that may still be delivered
  stays tracked until the connector settles it or it expires.
- **Act on the turn or session captured at decision time.** Stop, open, and deliver recheck that
  handle right before acting, so they never hit a newer turn or a renamed or reordered session.
- **No speech means no message.** A silent or empty take never submits to an agent; every output
  branch keeps the gates the insert path applies.
