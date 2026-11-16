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
  target.** A tie is different: asking interrupts, so a tie takes a predictable order (an agent
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
- **Nothing a take says outlives the take.** A name or number sends that one take there; without one, the take goes
  to the conversation captured in front at its press (`AgentTake.captureFocus`), and with none it is held with
  `AgentRecipient.nothingFocusedLine`. The front read lands after the press, so it counts only when no key press or
  click happened between the press and the read (`UserInput`, by each event's own time; an event that
  arrives late clears it through `AgentTake.noteUserInput` when its time falls in that window, and input after the
  read never does). Unobservable input confirms nothing, and every path that needs the front (delivery, `check on`, rename) says
  so with the Accessibility action (`AgentTake.unconfirmed`). The HUD, help and delivery
  read the same captured value. A keyDown a Carbon hot key consumes (`CarbonHotKeys.consumes`) never reaches the
  app, so it is not input. There is no remembered recipient: `open`, `check on`, and rename change
  nothing about later takes, and `select`/`choose` are ordinary message words. An address alone, or followed only
  by `please`, holds (`AskReason.nameOnly`). `ask` always sends, so a question put to the agent never becomes a
  local status answer; an unknown name after `ask` followed by a question holds rather than falling to the
  conversation in front, except after `the`, where a word that names no conversation is message text by design.
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

## Agents

The agent bridge (`AgentHub`, `AgentBridge`, `AgentHandles`, `AgentRecipient`, `AgentOutbox`,
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
- **A terminal acts as the app its process runs as.** A route may claim several bundle ids
  (`TerminalRoute.apps`); Open, the front read and the place script address the one the claimed process
  runs as (`TerminalRoute.bundle(of:)`). A helper process with no app of its own (iTerm's `iTermServer-*`
  after a restart) is claimed only by a route with a single app; with several, which app owns it is
  unknown, so it is not claimed rather than addressed to a guess.
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
  refreshes, reads places and freezes the roster only when an agent mode is eligible for it; the refresh
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
  alone only under the Agent mode's History choice. It is still never logged.
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
  `SpokenReplyCheck.calibratedCheckers` show the advisory. In Agent mode, "that sounded wrong" on its own is a
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
- **Clipboard files reach an agent by path.** In an agent take, copied files become their paths, and an
  image or PDF is saved under `AgentClipboard.defaultFolder` and becomes its path. Files older than
  `AgentClipboard.keptFor` are pruned at launch, every `AgentClipboard.pruneEvery`, and on each save. A saved
  image also rides the `submit` command's `images`, and the hub sends them only to a connector whose hello
  announced `images`; a connector reads each file just before submitting, and one it cannot read is left out
  while the path stays in the text. A send the agent rejects later is reported as refused.
- **An agent take is delivered whatever field has focus, a password field included.** The text goes
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
- **A spoken recipient never falls through to the conversation in front.** An unknown one holds and asks,
  like any unresolved target; one that fits several names goes to the first of them alphabetically
  (`AgentRecipient.resolve`), except a place label several conversations share
  (`AgentDirectory.sharedPlaceNames`), which asks. The shared labels are frozen with the take's names and
  passed to both the parse (`AgentRecipient.spokenNames`) and the resolve, for messages, open, and
  questions alike, so a bare label said without “tell” asks too instead of becoming a message. Names a
  place read produced during the recording are added for the same frozen conversations only
  (`AgentRecipient.addingLate`): they never replace a frozen name, add a conversation, or change the
  conversation captured in front and the rows. Whether a place label is qualified is decided per spoken label, across every place
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
  take that would go to the conversation in front is held, because its leading words may be a name a first read
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
  names, lives in that surface's own `Integrations/<Tool>/` folder (in `KeyScribeKit`, and in the app for a reader
  that runs commands, such as `HerdrPlaceReader`); only the registries and the composition root list them, and
  `SourceInvariantsTests` pins it. A label must be shown by that surface's current
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
- **An agent that takes messages during a turn gets the dictation at once, wherever it is.** A connector whose
  hello lists `steer` (Pi's, which sends with Pi's own `deliverAs: "steer"`) and bb (`--mode auto`) put the message
  into the running turn the way typing there does, with no keystroke, so focus plays no part. The policy hands it
  off (`AgentDeliveryContext.canSteer`) only while the agent works rather than waits on the user and nothing for that
  conversation is held or still being handed off; a held message is released to it the same way, oldest first,
  once the earlier one's receipt arrives (`AgentHub.confirm` frees the hand-off for a connector that steers, since a
  steer starts no turn). Pi takes a steer in only after the running tool calls finish, which can be minutes, so the
  connector confirms the receipt when Pi's `input` event accepts it, with no turn, and names the turn only when the
  steer enters the conversation, as `absorbed` at the `message_start` Pi emits while draining steering messages into
  the run (`agent-loop.js`). A steer Pi carries into a new run belongs to that run; a run that starts without a
  prompt digest keeps waiting for the `absorbed` (`AgentHub` `.turnStarted`). A later extension can still consume an
  accepted steer: it reads as sent, and no reply follows it.
- **A dictation reaches a running turn only as the user's own prompt, so only in front.** A connector's own
  prompt runs once the agent is idle (Claude Code queues a plugin's prompt behind the turn; measured on 2.1.325,
  2026-11-14), and only a prompt the user enters joins the turn as theirs. So for the conversation in front,
  while its agent works rather than waits on the user, the policy enters it (`AgentDeliveryDecision.enterPromptBox`,
  eligibility in `AgentHub.takesPromptBox`): the connector adds the text to the empty prompt box, never replacing
  what is there, and the take presses Return (`AgentTake.sendFromPromptBox`) only after three checks, in order:
  the conversation is the one in front; the connector answers that the box holds exactly the text and takes the
  keys (`promptBoxReady`); and, read again after that answer, the same conversation is still the one in front
  in the same window, since switching tabs or panes keeps the app and window. The `typed` count confirms it
  afterwards. Ask the engine whether a dialog holds the keys, with an empty append (`fill` refuses `dialog`):
  measured on 2.1.325 (2026-11-15), it refuses within about 120 ms of an approval or question opening and accepts
  again the moment it is answered, including while an approved tool runs, which tracking `tool.check` verdicts
  cannot match. A box answered as ready arms a guard for up to a second, until the user's prompt arrives: an
  approval or question decided meanwhile and an MCP input request (`Elicitation`) wait in the connector's hook, so
  the dialog is drawn after the Return lands, never under it (measured on 2.1.325, 2026-11-15: a held `ask` drew
  nothing until released). That covers a `tool.check` verdict of `ask` and any check of a tool that always puts
  its dialog to the person (`personTools`: a question, a plan to approve), whose dialog opens whatever the verdict.
  A box is not ready within half a second of any of these, which may not be drawn yet (draws took 120–360 ms). This bends “hooks never wait”: the wait
  is local, bounded, and happens only right after a steered dictation. A dialog that comes through neither hook
  is not held. Never fill
  text that starts with `/` or `!`: Return runs them as a command or in the shell, and the box drops the invisible
  character that keeps a submitted slash from running (measured on 2.1.325, 2026-11-15). A steered take follows
  only a turn that read it: the running turn once the connector reports it absorbed (the engine's `queued_command`
  attachment carrying the text, reported as `absorbed`), or the turn the message starts when the running one ended
  first, matched by its prompt digest (`followSteer`). It never claims a turn that did not read it, so its reply is
  heard once. A message for that conversation
  already held or still being handed off, an attached image, a connector without `box`, or a conversation not
  confirmed in front keeps the hold.
- **A lost receipt is not a lost message.** A connector keeps the receipt of a submission the agent already
  has across a lost connection and sends it on the next one, and a deadline overrun by the agent's own stall
  is restarted, not counted as a lost connection. The match is the connector's own mark, never the text or
  the input that came before it. Before the hub reports a take as uncertain it asks the connector where the
  submission is (`AgentHub.doubt`, the `check` command); a refusal the check finds goes through the same
  `AgentHub.refuse` a direct one does. A take left uncertain follows a turn's reply (`AgentHub.follow`) only
  when nothing contradicts it: never after the user typed in that conversation since the hand-off, never a
  turn that ended before the doubt, and never once a check (even a late one) said the message had not entered
  the conversation. A retried hand-off goes out under its own wire id (`AgentHub.Request.wire`), since a
  connector only acknowledges an id it has seen. Each hand-off keeps an `AgentDelivery` record, written to the take's History
  entry as its Delivery fact and logged at notice level when a receipt is missing or late; it holds times
  and fixed wording, never content.
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
- **Connectors name no terminal.** A connector reads only the environment keys and runs only the focus commands
  written into its configuration from the resolved routes (`ConnectorSurfaces`). A surface only the agent's own
  process can select declares a `FocusDefinition` and has Open ask the connector for it by id; the connector
  runs it without a shell, with each value a whole argument, after the expiry and session checks. A connector
  without the named command is outdated, never a silent fallback to another surface's focus.
  `SourceInvariantsTests` keeps surface names out of both connectors' sources. A connector's version covers
  its script and the focus commands, not the environment keys: a route that only adds keys rewrites the
  installed files on the next update without asking open conversations to reload, and a conversation still on
  the older key list keeps working, reporting only the keys it already reads, so Open for the new terminal only
  brings it forward until that conversation reloads. This relies on Claude Code loading a plugin from a local
  marketplace's own folder, not from its version-keyed cache: measured on Claude Code 2.1.325 (2026-11-13),
  `claude plugin list --json` reports `readFromFolder` for it, and `claude plugin update` with the version
  unchanged reports that edits in that folder take effect at the next session start or `/reload-plugins`. If
  a later Claude Code loads the cached copy instead, a keys-only change needs its own Claude version.
- **One agent, one adapter.** Everything particular to an agent (how its sessions are found, how its
  connector is installed and checked, its names, its reload command, its copy) lives in that agent's own
  `Integrations/<Agent>/` folder, behind `AgentDiscovery` and `AgentConnector`, with the facts shared code needs
  carried by `AgentKind` and `AgentSession`. Shared code never branches on an agent's name; a new agent is a
  new adapter and an `AgentIntegration` in the one list Settings and the runtime both build from
  (`AgentIntegrations.agents`). `SourceInvariantsTests` pins the boundary.
- **A host owns conversations that have no process of their own.** An app that runs agent conversations
  itself is an `AgentHost`: its conversations are listed with a host location (`AgentHostLocation`: host,
  instance, native id) and no pid. The conversation id comes from the location alone
  (`AgentHostLocation.conversationKey`), so the same thread id on two instances is two conversations. A host
  makes no call at all until the user turns it on in Settings (`Settings.Agents.hosts`) and its own
  `isEnabled`, a filesystem-only check that the tool is installed, agrees (`HostDiscovery.isEnabled`); turning
  it off drops its conversations on the next scan. A host turned on whose tool is not installed lists nothing
  and says so beside its switch; a host whose list could not be read keeps what it last listed and says so too,
  each with what to do next. A host is asked for its list
  only when the user may need it (a press for which an agent mode is eligible, Settings open, Check
  Again, turning it on),
  at most once per `HostDiscovery.fallbackInterval`, and otherwise once per `HostDiscovery.idleInterval`; a
  list that could not be read is asked again after the shorter interval. Another agent's hello or title never
  asks a host: a host's list is a separate program, and asking it on every event costs a run each time. The
  host's own connector greeting a conversation the host has not listed yet asks it once for that conversation
  (`AgentHub.expectListing`), so a new thread has its name by the time its first reply is read. A
  host id must not repeat an agent's
  or another host's (`AgentIntegrations.resolve`). Each capability a host's API lacks answers
  unsupported, never a guess.
- **A hosted conversation is reachable through its host.** It reads as Ready or Working rather than Not
  connected, offers Disconnect like any connected conversation, and Settings names it by the host. Its
  remembered name is kept until the host has answered once, so a refresh before the first scan never drops it.
- **A host call is bounded and never retried.** Delivery is one call with the request id: accepted reads as
  sent, queued as queued, and an uncertain or late answer as uncertain, never as not sent. Open and in-front
  wait at most `AgentHub.defaultHostDeadline`; a late open is not opened and a late in-front is unknown. A
  cancelled call is abandoned at once and its work cancelled, and Open hands the host its `stillWanted` check,
  which the host makes again after its own work and before it brings anything forward. A host
  that cannot take messages says so by name. A clipboard image reaches a host with its file path in the text,
  and as an attachment too when the host says it takes images (`AgentHost.takesImages`); the receipt says
  which.
- **An agent running inside a hosted conversation is filed under it.** A host names the environment keys
  that place a process in one of its conversations (`AgentHost.identityKeys`, `AgentHost.location(in:)`).
  While the host is turned on, an agent process whose environment places it in a conversation the host
  lists, and whose parent process is not placed in that same conversation (so only the agent the host
  started, never one that agent started), is not listed on its own. The hosted row keeps that agent's kind,
  setup and live state (`AgentConversation.innerAgent`), so connector updates, reload steps and setups still
  name the agent and an approval or dialog reads as it does in a terminal. Its connector is filed under the hosted conversation's id: the hub decides on each hello
  (`AgentHub.filing(for:)`), keyed by the connector's instance so the same connector moving to a new session
  stays filed, and the bridge then renames that connector's events and polls to the hosted id while its
  commands carry the session id of the instance that polls; its events also reach its own agent's discovery
  under its own session id, so an agent whose state comes from those events stays current. A connector filed in place of an earlier one
  sends the earlier one back to say hello. A connector that said hello before its host listed the
  conversation, or one filed under a host turned off since, is answered with a conflict
  (`AgentTransport.rehello`) so it says hello again and is filed afresh; a process placed in a conversation
  its host does not list yet has that host asked again at once, once per conversation. A second connector
  claiming a conversation another live connector instance holds is not filed. When an agent moves into its
  host's conversation, and back out when the host stops listing it, its Disconnect, chosen name and last use move with
  it (`AgentDirectory.carryChosenName`). The two ids stay linked for the rest
  of the run, so Disconnect and reconnect on either one apply to both, in either direction. An agent's process environment, and its parent's, are
  read only for the host's keys, once per process, and only while a host that names keys is turned on.
- **A reply is followed only into the turn that carries the dictated text.** A dictation delivered through a
  host is followed when the conversation's connector is live and reports `promptDigest`: its `turnStarted`
  carries `AgentPromptDigest.of` the prompt the turn started with, and the hub follows the earliest unmatched
  dictation with that digest. One the host queued waits however long the host keeps it, until the
  conversation is no longer listed; one the host took at once, or answered unclearly, waits at most
  `AgentHub.hostTurnWait`, so a later prompt with the same text is not taken for it. A reply that arrives
  while the host has not answered yet is held until it does: a refusal, or a Disconnect meanwhile, drops the
  dictation, the held reply and any turn already followed for it. A wait is checked when a turn starts, not
  only when the list is refreshed. A matched turn proves arrival, so an unclear answer is then reported
  as sent. A turn with another prompt, or none (a message the host itself injects), is never followed;
  messages the host merges into one turn match none and are sent without a spoken reply. Without a
  connector reporting digests, a hosted dictation is sent and never followed.
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
- **bb is a host reached through its own `bb` command** (`BBHost`). Every call runs the installed command with a
  fixed environment that turns bb's telemetry off, never the app's own. Delivery uses `--mode auto`, which steers a
  running turn and starts one when the thread is idle, as typing in bb does. The hub holds nothing back for an open
  approval: bb queues the message itself and answers `queued` (measured with bb 0.49.0 on 2026-11-15, Claude Code in
  a thread stopped on a command approval). The approval stayed open, the message sat in bb's queue as
  `waitingOn: interaction`, and once the approval was denied bb delivered it into the same turn. If a later bb
  steers into an open approval instead, the hub must hold the take as it does for a terminal agent. A queued
  answer's receipt names what the thread waits on, from the thread's state in bb's list. bb's `sent` reads as sent, and a
  dictation it steers into a running turn follows that turn's reply, `queued` as
  queued, its error envelope as refused in plain words, and anything else as uncertain; bb's error code goes to
  the log as public and its message as private, since a message could echo what was sent. Open only asks:
  bb's answer counts the clients it broadcast to, not a window that showed the thread, so it reads as requested, and bb is brought forward only when some client took it and the open is
  still wanted. In-front comes from bb's plugin (below), since bb's command reports no focused thread. While bb's app is not running its
  command is not run at all; the command never starts bb's server either (it fails at once, measured with bb
  0.49.0 on 2026-11-14). Its data folder is not watched: bb writes its database every few seconds even while
  idle (measured 2026-11-14), so a watch would run its command constantly. A thread nested under another
  is listed like any other: bb's `parentThreadId` is where the thread sits in its sidebar, which the user can
  rearrange by dragging, so it does not by itself say an agent started the thread. A thread's title is the label bb shows for it, so it names the
  conversation as a herdr pane title does: an `AgentPlace` `.title` label the scan carries
  (`AgentHostScan.found`'s `places`, kept through an unreadable list like any place), outranked only by a
  KeyScribe name, after which it still reaches the thread said in full after a verb. bb does not record
  whether the user or its title service wrote it, the same uncertainty a hook-set herdr title has; the
  agent never writes it. For a thread with no title bb shows its opening words (`titleFallback`) instead;
  they are what the user sees, so they reach the thread, but only said in full after a verb and never as its
  shown name (`AgentPlace.Label.onlyAfterVerb`, from `AgentHostScan.found`'s `shownInstead`), since they are a
  task phrase everyday instructions start with. A name the user gives a hosted conversation (spoken or in
  Settings) is also written to the host (`AgentHost.rename`; for bb, `bb thread update --title=`), so the
  thread's bb title says what to call it; the write runs after the name is saved, never delays the rename,
  and a failed write leaves the KeyScribe name in place. KeyScribe never writes a name it made up, so an
  untitled thread keeps showing its opening words. The bb plugin advertises `label` and draws the name it
  is sent on the thread's sidebar row, only when bb's title says something else (`rowLabel`), through bb's
  experimental row metadata slot. bb draws that slot only while its `threadRowMetadata` experiment and the
  thread list's `showRowMetadata` are on, so the first install or update turns on whichever is off
  (`BBSidebarSwitch`) and records what it changed in the plugin folder. The record keeps it from ever doing
  this again, so a switch the user turns off stays off. A switch bb could not read is left alone and tried at
  the next update, and a failed change never fails the install. Uninstalling turns off only recorded
  switches, and only when the user picks that button (`AgentConnector.undoesOnUninstall`). A location that is not a thread of this bb's data folder is never passed to the command. A
  list longer than `HostCLI`'s output cap reads as unreadable, not as the part that fit. An agent bb started
  is placed in its thread by `BB_THREAD_ID` together with `BB_THREAD_STORAGE`, which must be that thread's
  folder in this bb's data folder (`BBThreads.thread(in:instance:)`); bb passes the dictated text to the agent
  unchanged, so its digest matches (checked with Claude Code in bb 0.49.0, 2026-11-14), while bb's own
  messages to a parent thread arrive as turns of their own and are never followed.
- **One conversation per session id.** A discovery can list a session twice for a moment, for example while bb
  restarts a thread's Claude Code and the old process has not exited, so the hub keeps only the newest-started
  entry for each id as it assembles the list (`AgentHub.newestOfEach`), before anything downstream builds a
  dictionary keyed by conversation.
- **bb's plugin is a connector for every bb thread** (`BBPluginConnector`, sources in `Resources/BBPlugin`). It is
  installed like a connector, by the consent sheet's enrollment for bb's data folder, and bb is on exactly while
  that setup is enrolled, read from the enrollment itself, never copied into settings
  (`AgentsSettingsModel.isTurnedOn`; the hub rescans on every enrollment change,
  `ConnectorSetupRegistry.onChange`). Enrollment, not bb's report, decides it: a failed install or a plugin removed
  inside bb keeps bb on, reads Not installed, and offers Reinstall without asking again, and an enrolled setup always
  offers Uninstall. A revocation that could not be saved still holds in memory and is written before any reload reads the
  file (`ConnectorSetupRegistry.reload`); a grant that could not be saved changes nothing, so the file stays in
  charge. An unreadable setups file keeps the enrollment already loaded; at a launch that finds it unreadable, nothing is
  loaded yet, so bb reads as off until the file is fixed, as every connector is refused then. KeyScribe writes its sources and settings into its own support folder,
  then has bb install it from there (`bb plugin install`, which builds a path source itself and runs `server.ts`
  from that folder, so the settings file sits beside it). An update rewrites the files and asks bb to reload the
  plugin (`bb plugin reload`), which keeps the running copy if the new one fails to load; it runs at launch while
  bb is connected. Each copy of the app installs its own plugin id, the variant's connector slug, so release and
  development builds coexist. Installed means what `bb plugin list` reports for that id from that folder (missing,
  disabled, failed, or running), read only while bb is connected; a bb that does not answer reads as unknown. The
  plugin registers its teardown with bb (`bb.onDispose`), so a reload, disable or removal stops its connection and
  timers, and it logs connecting, waiting and stopping to bb's plugin log. Without its settings it marks itself as
  needing configuration rather than retrying; refused by the app (403 or 426) it stops. While the app is not running
  it watches the app's bridge folder and connects as soon as the app is ready, with a capped backoff besides. It
  honours Disconnect at the source: a quiet hello or a `quiet` command stops its reports for that thread until
  `admit`. While its host is turned off the bridge answers it as it answers a disconnected conversation
  (`AgentBridgeServer.silence(agents:)`, set by the hub at start and after each scan), and every change of that
  sends it back to say hello again, so a host turned off means it sends only identity. It greets at most a few threads
  at a time, so a large bb never overruns the bridge's listen backlog. A plugin bb reports failing, or running
  an earlier version after a failed reload (bb's status detail `reload failed:` on a running plugin), is
  installed but broken: Repair reinstalls it, launch maintenance tries once, and Uninstall stays offered. Inside
  bb it says hello once per thread as agent `bb` under the hosted conversation's own id, so it needs no filing, and
  one long poll serves all of them (a poll that lists `members` is answered with every member's commands and the
  members the bridge no longer knows, which say hello again on their own). It reports only what it saw: a
  `turnStarted` whose `prompt` is the digest of the queued row bb dispatched, or else of the newest prompt in the
  thread's history that is not still queued, and none for a row bb itself queued; a `turnComplete` only for a turn
  it saw start or found running when it loaded. Delivery stays bb's command, so the hub's digest follow matches the dictation exactly as for an
  agent's own connector. While it is live for a thread it holds that thread: an agent's own connector there is sent
  back and not filed until the plugin stops, so a thread never reports its turns twice. It lists bb's threads page by page, and a thread
  it had not listed says hello as soon as bb reports it working. Events the app cannot take are dropped, never
  replayed.
- **bb's plugin reports the prompt a thread waits on, as Pi's connector does.** On bb's `interaction.pending` it
  sends `waiting` with what bb records for that request (`waitingFor`, bounded like Pi's, with a title only where bb
  gives one), and repeats it in the thread's hello while it is open. Whether a prompt is open is state, not an
  event: a `waiting` report that does not land (no connection, a failed post, or a thread disconnected meanwhile
  and let back in) has that thread say hello again, so the hello carries the current prompt or none, along with
  the turn running, so the hub keeps a reply it already promised. The hello is said again at the end of the thread's
  queue of reports, never in place of it, so a reply queued behind the failed report is still sent and is never
  overtaken by a hello saying the thread is idle. A hello the app does not take for now (no answer, or an error
  other than a refusal) leaves the thread marked to say hello again once the connection is back. It asks bb
  whether the request is still pending only while one is open, every few seconds for the first minute and then
  less often, and a failed read keeps waiting rather than clearing; anything but pending, or the turn ending, sends
  the clear, before that turn's `turnComplete`. The hosted row reads as a dialog while the prompt is open
  (`HostDiscovery.observe`), so the hub describes it like Pi's; once cleared it reads as working until bb's list is
  next read, rather than asking bb's command again for every prompt. A list whose read began after the prompt
  opened and that shows the thread idle ends the prompt too, since a finished turn waits on nothing; a working
  thread keeps it, so the row never depends on whether bb's list flags every kind of prompt. Retiring the
  connector ends it as well.
- **bb's plugin gives every bb agent the read-aloud tool.** It registers one agent tool, named for its plugin id so
  each copy of the app has its own, and selects it for every thread; bb adds a plugin tool only when an agent session
  starts, never to one already running. The tool sends `notify` for the thread's current turn, or its next when
  idle. A thread already working when the plugin loads gets a turn of its own then, with no prompt (so it never
  matches a dictation), which its hellos name and whose end it reports, so that turn can still be read aloud. The whole call, queue included, has one deadline, and the agent is told only what
  the app answered. A Claude Code thread whose connector is installed also sees that connector's own tool. That
  connector is not filed while the plugin holds the thread, so its conversation is not listed; the hub hands its
  `notify` to the hosted conversation for the turn the plugin last reported running, in a `turnStarted` or a
  hello, or its next when none runs (`AgentHub.heldByItsHost`), so either tool follows the same turn and the
  reply is read once. While the conversation works on a turn the hub cannot name, it promises nothing.
- **bb's plugin says which thread you are looking at.** Its window half (`app.tsx`, an `experimental_appOverlay`
  mounted once per bb window, which bb builds when it installs or reloads the plugin) reports over bb's plugin
  RPC whether the window has focus and which thread it shows: a thread only on a thread page, and in a split
  only once the focused pane and the page agree (`shownThread`; they disagree for a few milliseconds during a
  switch, measured 2026-11-14), on every change and every few seconds while visible. The server half forgets a
  window silent past its heartbeat (a window reloaded with ⌘R never sends a blur), prefers a window focused now
  over focus history (a lost blur must not keep the old window), and says `shown` for that window's thread, or
  that none is shown, on one ordered path: retried until the app takes it, and said again after every connect,
  every hello and every Disconnect or Reconnect. The hub keeps one shown conversation per host, which an `on`
  replaces and an `off` clears, and forgets when that conversation is disconnected, since the plugin may have no
  connected thread left to send the clear through (a disconnected conversation's events never reach it). It hands
  it to the host only while that connector is live (`AgentHost.front(among:reported:)`). `BBHost` answers it only while bb is the frontmost app with a focused
  window, read on KeyScribe's side like a terminal's, since a window's own focus drops whenever another app is
  key, and the take then checks that window is the one focused at the press.
- **A host's command line runs through `HostCLI.run`.** It starts only an absolute program, in its own
  process group, with content on standard input rather than in the arguments. Standard output (the only
  output parsed) and standard error are kept apart, each capped, and cut output is marked. A deadline or a
  cancelled task kills the whole group, and a descendant that holds the output open cannot hold the call
  past its grace. A failure names the subcommand, never the arguments.
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
