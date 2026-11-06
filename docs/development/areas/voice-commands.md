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
- **An unresolved target holds and asks; it never falls through to the current, first, or default
  target.** A tie is different: asking interrupts, so a tie takes a predictable order (a Coding agent
  recipient tie goes to the first name alphabetically, a sidebar tie to the first in sidebar order) and
  asks only when no such order exists or a wrong guess would run the wrong action: different apps,
  places, or windows, or tabs in different browsers, tied for a switch are offered as a choice (`ui_design.md`, *Voice command
  choice*; `config_schema.md` has the full order).

## One rule, one function

- **Previews, advisories, examples, and uniqueness checks call the same matching function execution
  uses.** A second implementation drifts (word boundaries, case, normalization), and the preview then
  promises something execution does not do.
- **Strip parsed parts out of the original text; never rebuild the remainder.** Re-casing, re-joining,
  or re-normalizing the leftover corrupts content the user dictated (`npm test` must stay `npm test`).

## Coding agents

The coding-agent bridge (`AgentHub`, `AgentBridge`, `AgentHandles`, `AgentRecipient`, `AgentOutbox`,
the terminal routes, the agent adapters and their connectors) delivers dictated text to another program, so
every rule above applies to it, with these sharpenings:

- **Work with agents, terminals, and multiplexers as people normally start them.** Never require a
  launch flag, a wrapper, an environment variable, a named session, or an edit the user makes to
  their own configuration; only what installing an integration sets up itself, and removes again, is
  in bounds. Find each fact from what is already observable (processes, sockets, the tools' own
  read-only commands). A route that only works for one startup style is a bug for every other style;
  where nothing observable identifies a session, say unknown.
- **Confirm the intended session has focus, not a particular view of it.** A session visible in
  several places counts as focused when every view that could be in front shows it; when the front
  view could belong to another session, the answer is unknown, never a guess.
- **Minimal agent impact is a release requirement** (`docs/development/principles.md` §10).
  Observation hooks never await bridge work or perform I/O. They preserve downstream results,
  errors, cancellation, and other extensions' UI; connector failures must not interrupt agent work.
- **Bound background work across failures and reconnects.** A timed-out request still counts as
  outstanding until it settles. Idle checks, retries, queues, timers, and stored receipts must not
  grow with session age or failure count.
- **Validate connection identity on both sides of the bridge.** Recheck session, connection,
  expiry, and cancellation immediately before acting. Reconnection holds stale dictation for
  review; it never grants old queued commands permission to run again.
- **Reply text is in memory only.** A turn's final reply crosses the bridge bounded, for the spoken result of a
  turn the user's dictation started; it is never written to History or logs, and the only place it may go is
  the AI service the user chose for summaries, after redaction.
- **A Coding agent take is delivered whatever field has focus, a password field included.** The text goes
  to the agent the user addressed, not into the field, so the secure-field policy that keeps a dictation
  local does not stop it. The take is still left out of History (`design.md` §4.7), and the turn's reply
  can still go to the summary service like any dictated turn's.
- **Removal preserves user data and unrelated agent configuration.** Retire loaded connectors
  without waiting for them, verify uninstall state, and keep partial cleanup safe to retry.
- **A spoken recipient never falls through to the current recipient.** An unknown one holds and asks,
  like any unresolved target; one that fits several names goes to the first of them alphabetically
  (`AgentRecipient.resolve`).
- **A spoken recipient is matched as heard first, then as the mode's replacements and dictionary read
  it.** The reading only picks the name (`AgentAddress.parse`'s `read`, built by
  `ResolvedConfig.agentAddressReader`); the message after it, near misses, and ties come from the words
  as heard. A correction never picks between names: when the words as heard sound like another live
  name too, the address stays as heard. A take that a whole-utterance replacement owns is never
  corrected into an address; only a name said as it is addresses it. Accepted edge: at the start of a
  longer take, replacement or dictionary output that equals a live session name addresses that session.
- **Cancel withdraws the request itself, not just its HUD.** A message the user cancelled must not
  still send, and a cancelled message must not stay visible as if it will.
- **A receipt timeout is "unknown", not "failed" or "gone".** A request that may still be delivered
  stays tracked until the connector settles it or it expires. It holds later dictation for that
  conversation, so nothing overtakes it, but only for a bounded time (`AgentHub`'s hand-off limit); after
  that the queue moves on and the request is forgotten everywhere that tracks it (`AgentHub.onForget`), so
  tracking never grows with session age. What a connector reported for a session (its features,
  environment, title, prompt count, and label) is dropped once the session is neither listed nor
  connected, and its bridge registration goes with it, so the connector's next poll is refused and its
  hello reports everything again; metadata never outlives the registration that would let a connector
  skip that hello. The submit's own deadline ends at the receipt timeout, so a
  connector never starts a submission the hub has already reported as uncertain. A receipt
  within the hold settles the earlier take alone; a refusal after the hold keeps its text for review rather
  than queueing it behind newer takes.
- **Act on the turn or session captured at decision time.** Stop, open, and deliver recheck that
  handle right before acting, so they never hit a newer turn or a renamed or reordered session.
- **No speech means no message.** A silent or empty take never submits to an agent; every output
  branch keeps the gates the insert path applies.
- **One agent, one adapter.** Everything particular to an agent (how its sessions are found, how its
  connector is installed and checked, its names, its reload command, its copy) lives in files named for that
  agent, behind `AgentDiscovery` and `AgentConnector`, with the facts shared code needs carried by
  `AgentKind` and `AgentSession`. Shared code never branches on an agent's name; a new agent is a new
  adapter and a line in the composition root. `SourceInvariantsTests` pins the boundary.
- **Agents are isolated at the bridge.** Each agent has its own installation record, and retiring one
  agent's connectors leaves the others' sessions connected. Inside the app a conversation id is
  `agent:nativeId` (`AgentSessionID`); the bridge is the only place that translates, namespacing every
  event by the hello's agent and handing connectors their native id back, so two agents may reuse an id
  and never meet. Saved names carry the namespaced key; a legacy key gets the agent the composition root
  names. A connector advertises what it can do
  on its hello (`features`); a missing feature is unsupported unless that agent's shipped connector has it,
  which is the only case that reads as an outdated connector.
- **Discovery failure is not an empty roster.** A scan that cannot read its source says so, the hub keeps
  the sessions last seen for that agent, and Settings shows the problem beside that agent's connector.
- **An agent without a registry is discovered through its connector.** The hub hands every session event
  to the adapter of that event's agent (`AgentDiscovery.observe`, with the native id), so an adapter may
  build its roster from hellos, turn and title events; its scan then keeps only sessions whose process
  still runs, and retiring the agent's connectors forgets them (`AgentDiscovery.retire`). Such a session is
  never "not connected": without its connector it is simply not seen.
- **Discovery never runs on the main actor.** An adapter's `scan` does its reading off the main actor; the
  hub's `rescan` waits for it under a deadline (`AgentHub.defaultScanDeadline`) and treats a scan that does
  not answer like an unreadable one. `refresh` is the synchronous half: it applies the sessions last scanned
  and never touches a file, so a hello, a title or a turn ending is handled at once and only asks for a
  rescan afterwards. Concurrent rescans coalesce into the one in flight plus one follow-up. A scan that
  missed its deadline stays outstanding: no second scan starts for that agent until it settles, one observer
  waits on it however many rescans time out meanwhile, and its answer is applied by the next rescan. A
  stopped hub applies nothing and calls nothing back. A scan carries the time it began, and a title the
  connector reported after that time is never cleared by the scan's older registry name, even when the scan
  settles late.
