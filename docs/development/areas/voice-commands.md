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
  recipient tie goes to the first name alphabetically unless the name is a place label several
  conversations share, a sidebar tie to the first in sidebar order) and
  asks only when no such order exists or a wrong guess would run the wrong action: different apps,
  places, or windows, or tabs in different browsers, tied for a switch are offered as a choice (`ui_design.md`, *Voice command
  choice*; `config_schema.md` has the full order).

## Spoken grammar

- **A saved name acts only after its verb.** A place, link, or tab search follows a focus verb; a script or
  shortcut follows `run` (`VoiceCommandResolver.route`). A saved name said alone acts on nothing and answers
  with the phrase to say, which is what keeps a saved name from ever taking over a built-in command or
  ordinary speech, so never reintroduce a bare-name match.
- **A Coding agent recipient changes only on an explicit verb.** `select`/`choose` with an address selects
  (`AgentAddress.select`), `open` brings forward, and `tell`/`ask` or a name with a message sends; an address
  alone, or followed only by `please`, holds with the select hint and leaves the recipient as it was. `ask`
  always sends, so a question put to the agent never becomes a local status answer; an unknown name after
  `ask` followed by a question holds rather than falling to the current recipient, except after `the`, where
  a word that names no conversation is message text by design.
- **A status check is an explicit command, never a question.** Only a whole take starting with `check on`
  (or exactly `who needs me`) checks status (`AgentStatusQuery.parse`); every question is a message, because
  questions are what people say to agents. Focus never decides whether a take is a check or a message. An
  unknown target after `check on` holds like any unknown name unless it is longer than a name can be
  (`AgentRename.nameWords`), which makes it a message.
- **Local controls are whole utterances.** `cancel`/`never mind`, `go back`, and `repeat that` act only as the
  whole take, with an optional `please` around them (`VoiceCommandGrammar.parse`); inside a longer take they
  are text. A closing `please` is part of the words a text-taking script receives, and is dropped everywhere
  else. A standalone cancel records nothing in either action mode.
- **`conversation` and `session` are one word** wherever the grammar takes either (`AgentAddress.rowNouns`).

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
  Observation hooks never await bridge work or perform I/O. The one wait is a request the user or the model makes
  explicitly (the read-aloud tool and command): it waits for the app's answer within a bounded deadline, never for
  the turn or for speech, and a timeout promises nothing. They preserve downstream results,
  errors, cancellation, and other extensions' UI; connector failures must not interrupt agent work.
- **Idle means asleep.** Background work runs only while something needs it. The bridge wakes for a parked
  poll's deadline or a command not yet settled, never on a fixed tick (`AgentBridgeServer.reschedule`). The
  hub rescans quickly only while a conversation is connected or Settings is open, and otherwise on a change
  in a watched session folder (`AgentDiscovery.watchedFolders`) plus a slow fallback
  (`AgentRuntime.rescanInterval`); the first conversation to connect ends the slow fallback at once. A press
  refreshes, reads places and freezes the roster only when a Coding agent mode is eligible for it; the refresh
  stays, because a connector that resumes polling without a hello reports no event. Places are read when
  something needs them (a hello, a change in the listed conversations, that press), and on a timer only while
  Settings is open (`AgentHub.tickPlaces`): a terminal read is AppleScript or a CLI per surface, measured at
  about 4% CPU around the clock when it ran on a timer while a conversation was connected (2026-11-11).
- **Bound background work across failures and reconnects.** A timed-out request still counts as
  outstanding until it settles. Idle checks, retries, queues, timers, and stored receipts must not
  grow with session age or failure count.
- **Validate connection identity on both sides of the bridge.** Recheck session, connection,
  expiry, and cancellation immediately before acting. Reconnection holds stale dictation for
  review; it never grants old queued commands permission to run again.
- **Reply text is in memory only.** A turn's final reply crosses the bridge bounded, for the spoken result of a
  turn the user's dictation started or that the user asked from inside the agent to hear; it is never written to History or logs, and the only place it may go is
  the AI service the user chose for summaries, after redaction. What was read aloud is the one exception, and only
  once it is audible, or once it is shown when the voice is Off — text only (`SpokenResultOutput.onHeard`; a shown one has no
  reader): History keeps that line as heard, in its own field
  (`HistoryEntry.spokenReply`), never in `heard`, `transformed` or `result`, so nothing that learns from the user's
  speech reads it. It joins the dictation that asked for it only when that dictation was kept, and otherwise stands
  alone only under the Coding agent mode's History choice. It is still never logged.
- **Text only changes delivery, never the queue.** With `text_only` on, `SpokenResultOutput.play` shows an item instead
  of speaking it and holds it as the playing item until the panel reports it closed (`dismissed()`), so relevance,
  order, supersession, the in-front skip and stop all stay the code paths a spoken reply takes. A shown item waits
  while dictation is busy (`SpeechSilencer.isBusy`) or the panel is taken (`mayShow`), and the silencer's `onBusy`
  closes the one shown, because there is no synthesizer to stop. When an answer takes the panel, `yieldPanel`
  puts the shown item back at the front, so an item is never left playing where nothing shows it. Never advance the queue on a timer of its own, and
  never load the voice or lower other audio for a shown item.
- **Spoken audio is in memory only, and follows History.** Each reply the natural voice makes is one
  `SpokenAttempt` in `SpokenAttempts`: the text sent to the voice, the exact WAV handed to the player, the voice's
  details, and how playback ended. `DictationController.recordSpokenReply` holds the attempt while its History write
  runs and links it only once the write reports success, which is also when "Last Reply in History…" moves to it; a
  failed write or a take deleted meanwhile links nothing. An attempt no entry holds is dropped when its playback
  ends, so repeats, notices and previews keep nothing past it. `SpokenAttempts` removes every attempt an hour after
  it began on a timer, not on the next lookup, and that is why retention pruning needs no link cleanup: retention
  drops only whole days, the shortest choice outlasts the hour (pinned by
  `TakeReporterTests.everyRetentionChoiceOutlastsHeldSpokenAudio`), and even a hand-set shorter value is bounded by
  the same timer, and `SpokenAttemptLog` also bounds count and bytes; deleting the
  entry or quitting drops it at once. Nothing reaches disk unless the user chooses **Save Generated Audio…**, which
  exports the held bytes and never makes the audio again, or the reply is kept for diagnosis
  (`SpokenReplyDiagnostics.keep`: Sounded Wrong, "that sounded wrong", or Render Again), which writes
  the held bytes of every sentence played beside the entry (`HistoryStore.evidence`); History's **Play** (or **Play Generated Audio**, for a
  rejected take) plays those same bytes through `HeldAudioSpeech` and the silencer, and records nothing. `HistorySpeech` switches between it and the macOS voice inside the silencer's
  claim, so a reply queued behind it stays queued instead of starting and being cut off. The diagnostics report lists the recent attempts' metadata without their text
  (`SpokenAttempt.diagnosticLine`). Why the macOS voice read a reply is fixed wording, so it is kept with the entry
  (`spoken_reply.reason`); the audio is not. Attempt text, phonemes and normalized text are content: never log them.
- **A spoken reply check runs only when asked, and never outranks a dictation.** Check Audio in History, or Check
  beside a saved render, runs speech recognition on the natural voice's generated audio; it diagnoses the voice, not
  the recognizer. Nothing checks in the background, and Render Again only renders. `EngineKeeper.listen` refuses
  while a dictation runs and otherwise transcribes the whole WAV in one pass, as the threshold was calibrated. A
  commit polls the transcription gate's `isBusy` (`awaitSelfTestClearance(on:)`), which stays true until the engine
  call really returns, with no cap and no fresh gate: `SerializedEngine` would queue the dictation behind the check
  anyway, so a cap or a new gate only turns the wait into a lost recording. The HUD shows
  `HUDState.waitingForCheck`, stalled after `DictationController.checkStallSeconds`, with Discard Dictation and an
  Escape claimed without key focus, since the wait can be long; either discards the take. `EngineKeeper.checkGate` marks only a check that
  entered that gate, and clears when its work really ends, so a refused check never holds a later commit.
  A check keeps nothing by itself; only
  `SpokenReplyCheck.calibratedCheckers` show the advisory. In Coding agent mode, "that sounded wrong" on its own is a
  command only while reply updates are on and a reply has been heard; anything else, including a message addressed
  to a conversation, reaches the agent.
- **One synthesis at a time on the natural voice.** `KokoroVoice` admits replies, previews and the install check
  through one `InFlightWork.runAlone` gate, held until the work truly returns, not when it is cancelled or times
  out. Anything that finds it busy (a reply right after a stop, or a preview) waits up to `NaturalSpeech.busyWait`
  for the earlier work to settle, inside its own deadline, and only then goes to the macOS voice; the cap on
  unfinished syntheses keeps a wedged one from making every later reply wait. Removal closes admission, including
  warming, before it waits. The output device is read off the main actor and only when the natural voice made audio. Audio with invalid samples, none, or no audible level (`SpokenAudioCheck`) never
  plays. The check cannot tell intelligible speech from right-length noise, so never word a fallback as having
  detected garbling.
- **Clipboard files reach an agent by path.** In a Coding agent take, copied files become their paths, and an
  image or PDF is saved under `AgentClipboard.defaultFolder` and becomes its path. Files older than
  `AgentClipboard.keptFor` are pruned at launch, every `AgentClipboard.pruneEvery`, and on each save. A saved
  image also rides the `submit` command's `images`, and the hub sends them only to a connector whose hello
  announced `images`; a connector reads each file just before submitting, and one it cannot read is left out
  while the path stays in the text. A send the agent rejects later is reported as refused.
- **A Coding agent take is delivered whatever field has focus, a password field included.** The text goes
  to the agent the user addressed, not into the field, so the secure-field policy that keeps a dictation
  local does not stop it. The take is still left out of History (`design.md` §4.7), and the turn's reply
  can still go to the summary service like any dictated turn's.
- **Removal preserves user data and unrelated agent configuration.** Revoke the setup's installation
  first, retire its loaded connectors without waiting for them, verify uninstall state in that same setup,
  and keep partial cleanup safe to retry; retrying never readmits the revoked installation.
- **A connector is installed into a setup the user chose, never the app's own environment.** A setup is
  the folder an agent loads its configuration from, found from each conversation's own process
  (`AgentProcesses`, `AgentProcessTable`), an enrolled setup, or a folder the user chose. A relative setup
  variable is resolved from that process's working folder (`FolderPath`). Every
  operation takes an explicit `ConnectorTarget`, and a command run for it gets that setup's variable set
  (or removed for the default) explicitly. Discovery never installs or enrolls; only the consent sheet does
  (`ConnectorSetupRegistry.grant`). `SourceInvariantsTests` pins where a setup variable may be named.
- **Installation authorizes a setup; exclusions take conversations back out.** Every current and future
  conversation of an enrolled setup connects, except those the user disconnected (`AgentExclusions`, saved
  in `names.json`). Check exclusion at the bridge (a quiet hello carries identity only, later events are
  dropped), in the connector immediately before it submits (a submission held for the keyboard is refused
  once the conversation goes quiet), in the hub before every hand-off and after every wait, and in the take
  before any rewrite. Saved choices that cannot be read admit no conversation; a disconnection that cannot
  be saved still holds for the session and says so. Uninstalling a setup silences spoken replies for its
  conversations exactly as Disconnect does.
- **A disconnected conversation keeps its name.** The directory names connected and disconnected
  conversations together (`AgentDirectory.update(excluded:)`), so disconnecting never renames a
  conversation and no other conversation takes its name.
- **A spoken recipient never falls through to the current recipient.** An unknown one holds and asks,
  like any unresolved target; one that fits several names goes to the first of them alphabetically
  (`AgentRecipient.resolve`), except a place label several conversations share
  (`AgentDirectory.sharedPlaceNames`), which asks. The shared labels are frozen with the take's names and
  passed to both the parse (`AgentRecipient.spokenNames`) and the resolve, for messages, open, and
  questions alike, so a bare label said without “tell” asks too instead of becoming a message. Names a
  place read produced during the recording are added for the same frozen conversations only
  (`AgentRecipient.addingLate`): they never replace a frozen name, add a conversation, or change the frozen
  recipient and rows. Whether a place label is qualified is decided per spoken label, across every place
  that has it, not per container. A qualified place name stays once given (`cos claude` keeps its
  qualifier after its sibling closes, and across an app restart through its remembered name), because the
  user may have learned it and the words after a name are the message.
- **A conversation's name is the one the user sees.** The order is a KeyScribe
  name, what herdr shows on its pane (a `.title` then a `.pane` `AgentPlace.Label`), the name the user gave
  the agent in herdr (an `.agent` label, read from `herdr agent list`), the agent's own user-set name, the
  user's label for its place (`AgentPlace`, read for herdr by `HerdrPlaces` and `HerdrPlaceReader`, and
  for tmux, Zellij, Ghostty and iTerm by `TerminalPlaces.walk` over each `PlaceRoute` and
  `ScriptedTerminalRoute.placeScript`, through `TerminalPlaceReader`; `CombinedPlaceReader` joins them
  innermost first and any unknown answer is unknown: tab, then workspace), then the folder. A terminal read
  that fails is unknown only for a conversation that already had a place (`AgentPlaceQuery.placed`), and
  absent otherwise, so a hiccup keeps names but never holds dictation for one that had none. A terminal app
  read that fails or is not allowed (`TerminalScripting.read` reports an undecided Automation grant as a
  failure) drops only that app's labels and reuses its last answer; it is never unknown, so an app the user
  has not yet allowed never holds dictation. The walk goes on
  past herdr through its focus route to the terminal around it, and `CachedTerminalFacts` asks each server
  once per read. Each label carries its surface's own word (`AgentPlace.Label.term`). The walk takes
  the agent's environment from its connector report, because an agent that rewrites its process title (Pi)
  cannot be read from outside. A terminal app is scripted only through the passive read, which never asks
  for Automation. A label that
  cannot be said falls through to the next one. A place label is joined to its conversation by the
  session herdr reports for the pane, and only for a pane where herdr reports no session, by the pane id in
  the agent's environment; a pane id is only meaningful with its server's socket, so every place is keyed
  by socket. The environment's pane id is resolved through herdr's own `pane current` with that id as the
  caller's pane, because herdr gives a moved pane a new id and resolves the old one only for its caller.
  Labels are read off the main actor, by one coalesced read per poll for every conversation
  (`AgentPlaceTracker`), each command under a timeout, never on the registry tick's critical path and
  never awaited by the agent. Whether a conversation's place was checked is tracked per conversation
  (`AgentPlaceTracker.checked`): found or absent checks it, and it stays checked. Separately, any completed
  answer, unknown included, marks it attempted (`AgentPlaceTracker.attempted`). An unknown answer keeps the
  labels last read, so a name is never lost to a failed read, and records when reads stopped working
  (`AgentPlaceTracker.failingSince`), from the first failure, which Settings and the Rename sheet show beside
  the conversation instead of blocking on it. An unchecked conversation with no cached place keeps its last name
  (`AgentDirectory.update(unplaced:)`), so a failed first read after launch keeps remembered names. A take
  waits for a read already running only when it is resolved, up to `AgentTake.placeNamesGrace`,
  and never for Go back or Repeat that, which name no conversation;
  if a read is still running then, or any listed conversation has no completed read yet (`placesUnread`), a
  take that would go to the default recipient is held, because its leading words may be a name a first read
  did not deliver (a new conversation whose pane already has a label). A read that completes, even unknown,
  never holds: a pane renamed during an outage and then addressed bare is the one case left, and the receipt names
  where the take went. Holding instead would block the main path for the whole outage, and some outages are
  permanent (a herdr without `agent list`, an environment pointing at a dead herdr socket). A lookup is found, absent, or unresolved
  (`HerdrPlaces.Association`): two panes claiming one session, a pane claimed by another session, or an
  unreadable listing or environment is unresolved and keeps the labels last read; only a good listing with
  no pane for the session, or herdr reporting the pane gone, removes them. Unreadable never means unnamed.
- **A place reader emits only names the user can see and provably set.** Each surface gets a reader behind
  `AgentPlaceReading` that emits `AgentPlace` labels by level; the directory and the resolver stay
  surface-blind, so a reader never implements addressing. Everything one surface needs, its focus route and its
  names, lives in files named for it (`HerdrRoute`, `HerdrPlaces`, `HerdrPlaceReader`, `TmuxRoute`, `GhosttyRoute`,
  …); only the registries and the composition root list them, and `SourceInvariantsTests` pins it. A label must be shown by that surface's current
  configuration (tmux with its status line and pane borders off shows none), must be one the surface keeps
  apart from the title a program writes through OSC 0/2 (which Claude Code and Pi set to generated text, so
  it is never read: herdr's `terminal_title`, and Terminal.app's custom title, which receives it), and must be
  joined to the conversation by its tty, pid or environment. An outer title that mirrors the active inner
  pane belongs to that pane alone, never to every conversation behind it. `.title` is for a separate,
  hook-set display field; `.agent` for a handle the surface's own commands target. A new reader is checked
  against the surface's real output first, then by hand: name the place and say it, let the agent retitle
  itself and confirm that is not a name, rename the place and confirm the name follows.
- **One shown name; other names by kind.** `AgentDirectory.otherNames` freezes each conversation's other
  names with the take as `SharedName`s whose `kind` says what they may do: a pane label or herdr agent name
  (`.also`) reaches it like a name and beats a shared place label; a name of uncertain provenance, a pane
  title that lost or the agent's own name a herdr name outranked (`.afterVerb`), reaches it only when said in
  full after “tell”, “ask” or “open” (`AgentAddress.parse`'s `afterVerb`, and `AgentStatusQuery.parse`'s),
  never in part, since such names are task phrases everyday instructions start with; a
  tab or workspace label of one conversation (`.held`) holds with `AskReason.shownOn`. One another name two
  conversations have asks; one equal to a shown name is dropped. A herdr agent name is grouped only with
  other agent names when deciding whether it is shared.
- **A title the agent generated never becomes a name.** An adapter reports what it knows to be generated as
  `AgentTitle.generatedTitle`, and a connector-reported name equal to it is ignored for naming
  (`AgentHub.isGenerated`).
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
- **Agents and setups are isolated at the bridge.** Each enrolled setup has its own installation id
  (`ConnectorSetups`), and retiring one installation's connectors leaves every other setup's and agent's
  sessions connected. Inside the app a conversation id is
  `agent:nativeId` (`AgentSessionID`); the bridge is the only place that translates, namespacing every
  event by the hello's agent and handing connectors their native id back, so two agents may reuse an id
  and never meet. Saved names carry the namespaced key; a legacy key gets the agent the composition root
  names. A connector advertises what it can do
  on its hello (`features`); a missing feature is unsupported unless that agent's shipped connector has it,
  which is the only case that reads as an outdated connector.
- **Discovery failure is not an empty roster.** A scan that cannot read its source says so, the hub keeps
  the sessions last seen for that agent, and Settings shows the problem beside that agent's connector. A
  scan that read only part of its source keeps what it last saw from the unread part (`AgentScanExtras.carried`)
  and returns the rest fresh; only carried conversations are labeled Last seen.
- **An agent without a registry is discovered through its connector and its processes.** The hub hands
  every session event to the adapter of that event's agent (`AgentDiscovery.observe`, with the native id),
  so an adapter may build its roster from hellos, turn and title events; its scan then keeps only sessions
  whose process still runs, and retiring an installation's connectors forgets them
  (`AgentDiscovery.retire`). A running agent process no hello has identified is a candidate
  (`AgentCandidate`): listed so the user can connect it, never a recipient, and matched to its hello by
  process id and start time, never the process id alone. Processes that could not be read make the scan
  partial, never empty, and only when the process's own name is the agent's; a candidate whose process
  could not be read stays listed. The process table is listed once for every agent's discovery and reused
  until it ages out (`AgentProcessTable`), so the liveness tick never sweeps it per agent.
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
