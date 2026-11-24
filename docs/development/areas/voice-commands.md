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
  unknown target after `check on` holds like any unknown name when it is no longer than a name can be
  (`AgentRename.nameWords`), or when, longer, it begins a known name or a title shown only after a verb, such as an
  Ultimate sidebar title (`AgentStatusQuery.begins`); any other longer target is a message.
- **Local controls are whole utterances.** `cancel`/`never mind`, `go back`, and `repeat that` act only as the
  whole take, with an optional `please` around them (`VoiceCommandGrammar.parse`); inside a longer take they
  are text. A closing `please` is part of the words a text-taking script receives, and is dropped everywhere
  else. A standalone cancel records a Cancelled History entry in either action mode, so it never looks lost.
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

- **An Agent take sends; it never leaves words for the user to send.** The whole act is: press the Agent
  key, speak, release. The user does not see the text and does not press Return, and they rely on that.
  Whether the conversation is in front or behind, has a draft in its box, is mid-turn, or has no thread
  yet (a fresh new-conversation page), the take is submitted for them, as close to the same experience as
  the agent allows. A path that fills a box and waits for Return is a defect to fix, not an option to
  offer: someone who wants to read before sending uses an ordinary dictation mode, after “open …” when
  the conversation is in the background. Only when sending is impossible does a take read as waiting in
  the prompt box, and the HUD says so.
- **Work with agents, terminals, and multiplexers as people normally start them.** Never require a
  launch flag, a wrapper, an environment variable, a named session, or an edit the user makes to
  their own configuration; only what installing an integration sets up itself, and removes again, is
  in bounds. Find each fact from what is already observable (processes, sockets, the tools' own
  read-only commands). A route that only works for one startup style is a bug for every other style;
  where nothing observable identifies a session, say unknown.
- **A host server is not its conversations' terminal process.** Ultimate keeps its server PID for
  project liveness, but its browser conversations have no terminal PID. Reading terminal places for
  that server borrows the launcher's names and delays new conversations. Codex threads can carry their
  actual command-line process, so they still take terminal places.
- **Ultimate's file index is partial.** It omits owned subagents. While the installed connector answers, its `list`
  action is the roster and the one listing rule (`server.ts` `unlistedReason`, `listing`): the app takes each row as
  given, with its handle, sidebar title, folder and last activity, and keeps no rule of its own. The same rule gives
  the reason a page showing an unlisted conversation cannot take a take. When the connector is not installed, is
  turned off in Ultimate, or has not opened yet, the app lists from the file with only the root and the lander left
  out, so the project stays listed. Once the connector has listed a project, a list call that fails keeps that list
  and says the project did not list, rather than swapping to the file's names for a scan. A conversation the page shows before the file has it is listed by the connector
  (`fresh`, bounded and expiring); its hello makes the app rescan, so the app keeps no copy of it.
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
  The Ultimate connector's `KEYSCRIBE_ULTIMATE_TRACE` file trace is strictly harness-only (it uses
  synchronous `appendFileSync` inside Ultimate's server process, logs only allowlisted protocol
  metadata without user/reply/problem text, and is never set in normal operation).
- **Idle means asleep.** Background work runs only while something needs it. The bridge wakes for a parked
  poll's deadline or a command not yet settled, never on a fixed tick (`AgentBridgeServer.reschedule`). A parked
  poll keeps its connector live only while its connection is open: a connector whose process ends closes it, and
  the bridge drops the poll then rather than at its deadline (`AgentBridgeServer.watchForHangUp`), so a stopped bb
  server stops counting as holding its threads within the active window. The
  hub rescans quickly only while Settings is open, and otherwise on a change in a watched session folder
  (`AgentDiscovery.watchedFolders`), on a connector's hello, turn start and turn end, once a connector that hung up no
  longer reads live (`AgentBridgeServer.onHangUp`), plus a slow fallback (`AgentRuntime.rescanInterval`). A
  connected conversation is no reason to scan quickly: its connector reports its turns, and a rescan every second
  while one was connected cost 12 to 15% CPU on a Mac running about 980 processes (2026-11-20). Each agent's processes
  are classified once per process listing (`AgentProcessTable.found`), however many scans ask within it. A press
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
  the AI service the user chose for summaries, after redaction, together with the dictation the reply came right
  after, which the hub holds in memory for its recent deliveries only. A connector reports what a reply came after
  (`turnComplete`'s `from` and `prompt`) only from what its agent tells it; a message it cannot place or identify is
  left unnamed, never guessed. What was read aloud is the one exception, and only
  once it is audible, or once it is shown when the voice is Off — text only (`SpokenResultOutput.onHeard`; a shown one has no
  reader): History keeps that line as heard, in its own field
  (`HistoryEntry.spokenReply`), never in `heard`, `transformed` or `result`, so nothing that learns from the user's
  speech reads it. It joins the dictation that asked for it only when that dictation was kept, and otherwise stands
  alone only under the Agent mode's History choice. It is still never logged.
- **The log says what became of each reply, never what it said.** `SpokenResultOutput` notes, as public `agents` log
  lines, each reply queued, read aloud or shown, and each one not read with its reason (`Unread.reason`, the same
  reasons History gives as `Unread.line`), naming only the request the take sent and the agent's kind, which the hub
  passes in. Conversation names, handles and reply text stay out of every line, so nothing private has to be hidden
  for the line to be read. Notices and answers to a check are not replies and are not noted, and a reply that
  arrives while reading replies is off never enters the queue, so it is not noted either.
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
  command only while Read Agent Replies Aloud is on and a reply has been heard; anything else, including a message addressed
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
  (`AgentProcesses`, `AgentProcessTable`), a connected conversation's installation (the hello's `installation`
  names the enrolled setup it was installed in, so a Pi whose process cannot be read still has its folder), the
  folder variable in the user's login shell, an enrolled setup, or a folder the user chose. A relative setup
  variable is resolved from that process's working folder (`FolderPath`). Every
  operation takes an explicit `ConnectorTarget`, and a command run for it gets that setup's variable set
  (or removed for the default) explicitly. Every agent and tool command runs from `ToolCLI.workingFolder`, a folder inside the
  home folder but never the home folder itself: run from home, removing a plugin from another Claude Code setup also
  removed it from the default one's `~/.claude/settings.json`, and run from a folder inside home it did not (Claude Code
  2.1.329, a throwaway home, 2026-11-20). Inside home rather than `/` keeps what a version manager's shim finds by
  walking up from the working folder, such as a `.node-version` in the home folder. Discovery never installs or enrolls; only the consent sheet does
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
  it is never read: herdr's `terminal_title`, and Terminal.app's custom title, assumed but not yet checked to receive it: run
  `KeyScribe --title-probe` with Codex in Terminal.app and record what it prints before relying on it), and must be
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
- **A conversation keeps answering to the name it had just before.** Whatever displaces the name it answered
  to records that name as its previous one (`AgentDirectory.formerNames`): a rename, Use Default Name, the agent's own name, a
  place label that changes or is first read (a tmux session read once the connector reports `TMUX`), and a
  remembered name that loses to such a label on the first read after a restart. An automatic change keeps only
  the name it replaced; a rename also keeps the previous name it found unless the name it replaces is one the
  user chose, so a name the user was using is never pushed out by a label they did not set. Previous names are
  saved with the remembered name (`RememberedName.previous`, under the same pid and start time), so they
  survive a restart, an update, and a connector reinstall, and move with a chosen name when the session id
  changes (`AgentDirectory.carryChosenName`, which takes them from the hub before the rescan that drops the old
  id). A previous name reaches its conversation only while nothing else answers to it: one that is another
  conversation's current name, chosen name, or remembered name is that conversation's alone; one that is a place
  label several conversations share asks, as the label does; one several conversations had is a shared name that
  asks. All of this is derived in one place, `AgentDirectory.indexPreviousNames`, from the names, place labels
  and previous lists; routing and the saved file read `previousNames(of:)`, which never holds the current name.
- **An integration owns its own conversation ids; shared code never reads one.** An integration whose
  conversations have ids people say (a numbered branch, a ticket id) registers an `AgentNativeAddress` on its
  descriptor (`AgentHostIntegration.addresses`, or `AgentIntegration`'s for a terminal agent): a pure, synchronous
  function from the words after the verb to a native id and how many words it used, or to "mine, but no valid id".
  It never sees the roster, the command or the message. Shared code freezes the take's `AgentNativeRoster` with
  the names (`AgentHub.nativeRoster`: connected and disconnected conversations with their current name, every
  other name that reaches them, and the same workspace the directory names them by; a workspace settled after the
  press fills in a frozen conversation's, and no conversation joins after the press) and decides everything else in `AgentAddress.parse`: one conversation sends, several ask by their
  current names, none holds and is never taken for a shorter name or the conversation in front. A reading competes
  with the name match by words used: the longer wins. On a tie with an exact name, a reading that found no
  conversation yields to the name; otherwise the name's conversation joins the reading's, so a default name equal to
  another project's address asks instead of picking one. A tie with a partial name goes to the reading. Readings of
  the same length from different integrations are pooled, so registration order never matters. A leading workspace
  label narrows a reading to that workspace's conversations. A reading that ends inside a spoken word holds. The
  reading also runs on the user's replacements and dictionary (the address reader), as names do, and word by word
  only when they change the first words. A reader is active
  while its integration is turned on or its agent has a listed conversation, so an address still holds while
  discovery is empty or unreadable, and its words mean nothing to someone who never turned it on. Spoken numbers
  come from `SpokenNumber`; each integration picks the forms it accepts, and an "and" continues a number only after
  "hundred" or "thousand". Settings' shorter-name hint runs the same parse with the same roster. A conversation
  whose own default name is another project's address (an untitled branch beside a titled one with the same number)
  is named by its project, so the name it shows always reaches it.
  `SourceInvariantsTests` keeps `Int(…native)` out of shared code.
- **A title the agent generated never becomes a name.** An adapter reports what it knows to be generated as
  `AgentTitle.generatedTitle`, and a connector-reported name equal to it is ignored for naming
  (`AgentHub.isGenerated`).
- **A spoken recipient is matched as heard first, then as the mode's replacements and dictionary read
  it.** The reading only picks the name (`AgentAddress.parse`'s `read`, built by
  `ResolvedConfig.agentAddressReader`); the message after it, near misses, and ties come from the words
  as heard. A reading that covers more spoken words than the name heard as said wins, as the longest name does
  when heard (“ultimate sixty one” reaches `ultimate 61`, not `ultimate`). A correction never picks between
  names: when the words as heard sound like another live name too, the address stays as heard. A name made of the
  first words of the name read is not such a rival (the longest name decides between them), and a reading that only
  writes numbers as digits is exact, not a correction, so this check does not apply to it. A take that a whole-utterance replacement owns is never
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
  accepted steer: it reads as sent, and no reply follows it. Claude Code's connector lists no `steer`, so its
  takes for a working conversation wait in the hub's queue for the turn to end (below).
- **In Pi, omp and Ultimate, input that arrives once the agent has answered starts a turn of its own, even inside one run.**
  An extension's message, another agent's, or one typed or steered in after an assistant message that ends without
  a tool call ends the running turn there, so the answer to the dictation is reported at once and is never replaced
  by the reply to what followed; that later turn reports `from: other` when an extension's message started it. Pi
  marks no difference between a message from someone else and an extension continuing the user's request (a stop
  hook, plan-mode's execute step), so a continuation of that kind also starts a turn of its own, and its reply is not
  read as the dictation's. omp tells its own continuations apart (`agent_end` with `willContinue`), and those stay
  in the turn (`Core.paused`). Input that arrives while the agent is still working (after a tool call) stays in the
  turn, and its reply names no request. The Ultimate connector applies the same rule to the entries it sees
  (`input` after `replied` with a final reply ends the turn there). Claude Code and Codex need no rule: input after
  the agent's final message starts a new turn of the host's own. bb (a Codex-style turn) can take a message into the
  turn while the final message streams; its plugin sees only the thread going idle and the last assistant text, so a
  reply there can still answer a message that came after the dictation, and the cue names that sender when bb
  records one. Ultimate names an input's sender from its entry kind (`senderOf` in its connector): `pi.user` is the user,
  `board.*` another conversation, `automations.fired` a schedule, and anything else Ultimate submits (a subagent's
  report, a side-chat summary, a watchdog or pause note) is its own note, which never replaces the input already named
  for the turn and alone reads as someone else's. Claude Code's background-task notice (`task-notification`) absorbed into a running
  turn likewise never replaces the input already named for it; a turn it starts alone reads as after a background task. A note the host writes itself is never that sender: the cue looks at the last message a turn took that
  the host did not write (`SpokenResult.cause`, `AgentAcceptedMessage.fromHost`), so a dictated turn that bb also fed
  a child thread's outcome is still read as the dictation's answer.
- **Pi and omp share one connector core, with an adapter per agent.** `Resources/PiConnector/index.ts` holds the core
  (queue, poll loop, submissions, receipts, read aloud, focus) and each agent's adapter for the signals that differ;
  the installer writes `installedFor` and gives each agent its own folder under `extensions/` (the plugin name with
  the agent's id added, `ExtensionAgent.folderName`; only Pi's keeps the bare plugin name it had first), and an adapter stays inert in another agent's host, so a folder both agents load holds
  both connectors and never runs one in the wrong agent. `installedFor` picks the adapter; the host check
  (`hostedByOmp`) only guards it, and it takes the host for omp only on a positive marker of omp's extension API
  that Pi's has no counterpart for (`arktype` on the API object, as measured on omp 18.22.2 and Pi 1.5.0,
  2026-11-18). Anything else is Pi: omp is never inferred from something missing, and a name both agents' packages
  export never decides it. omp's adapter reads its version from the package omp puts on the API (`pi.pi.VERSION`)
  and reports an empty one when that is missing. A fix in the core is a fix for both: run both suites
  (`make test-pi-connector`, `make test-omp-connector`). omp's floor (`OmpCLI.minimumVersion`) is the oldest omp the connector has run
  against, and the copy says so when it reports omp too old. Older packages expose the same events and API members
  back to omp 18.20.1, the first with `session_clear` (packages compared, not run, 2026-11-21); lower the floor only
  after `make test-omp-connector` and the live omp run pass against that version. omp's adapter rests on behavior observed on omp 18.22.2
  (2026-11-18), not on its docs: an idle conversation is never sent a follow-up (omp holds it until some later
  run); a steer is confirmed when its send resolves, which is when omp queues it (omp gives an extension's message no
  `input` event; an idle send resolves only when its run ends); while a tool approval or the `ask` tool is open, a
  dictation goes as an aside (the adapter's `promptDelivery`; Pi's adapter sets none, since every Pi prompt holds
  delivery), which omp delivers at the next step without answering the prompt (a steer would deny
  or dismiss it), and is confirmed the same way; delivery holds while a plan review is open, because omp is idle then
  and any send starts a run that replaces the review; a message omp refuses (its cost cap) is put back in its editor
  by omp, so the connector swaps it for the user's own draft or clears it; a tool approval reports waiting with
  omp's reason for asking as its title when omp gives one (such as a bash safety pattern, a bash rule from the user's
  settings, or a restricted folder; an approval the approval mode alone asks for gives none), and names the tool
  being approved by its call id rather than the last tool started, because omp runs tools side by side and an
  approval arrives just after its own tool's start (an MCP tool is approved as omp's `write` to an `xd://` path);
  omp raises no event for a picker or confirm that one of its own commands or another extension opens, so those are
  not seen: the connector reports no wait and holds nothing for them; a rename raises no event either, so the
  adapter reads the name the user set (`titleSource: user`; a generated title is `auto` and never sent) at run
  boundaries, each time the core's poll returns (`Adapter.retitle`, at most one poll hold apart, sooner when the
  app sends a command), and once `retitleDelay` after the user's input, because a typed `/rename` changes the
  name only after omp's `input` event, once its title model has put an icon on it (470–520 ms later in three
  renames); each read is a name lookup and a compare, and only a change sends anything; an image
  sent with a dictation, idle, as a steer or as an aside during an approval, reaches the model as Pi's does, but omp passes it on only to a model
  its configuration says takes images and gives any other model a note in its place; and only
  an `agent_end` without `willContinue` finishes a turn (omp reports itself idle while background work keeps the run
  open). omp also has no way to load a new connector into an open conversation: `/reload-plugins` keeps the
  loaded extension module, and an extension command's `ctx.reload()` only re-reads the conversation's file while
  aborting its running turn and dropping queued messages (omp 18.22.2, 2026-11-18). So omp's `AgentKind` has no
  `reloadCommand` but a `resumeCommand`, and its copy says to quit a conversation and reopen it with
  `omp --resume`, which loads the installed connector into the same conversation, history and title kept. On the Swift side both agents are an `ExtensionAgent` descriptor over `ExtensionConnector` and
  `ExtensionDiscovery`, so the agent's own folder holds only its rule, CLI parsing and the copy that is its own. The
  rule (`AgentProcesses.Rule`) is the one place an agent's command, folder variable and default folder are spelled;
  the integration, connector and discovery read them from it. The rest of the copy is built from the agent's name and
  reload command (`AgentConnectorCopy.extensionAgent`), so every agent's wording stays the same. A connector whose
  files are current but whose agent cannot say whether it is turned off is installed but unconfirmed
  (`AgentConnectorModel.State.unconfirmed`): never Ready, never repaired by an update, and checked again by Try Again.
- **A host says who delivers each conversation's dictation** (`AgentHost.deliveryRoute`): the host itself, through
  its own command or server (`deliver`), or the connector it installs, through the bridge `submit` path with its
  receipts, steering and checks. The hub takes the declared route and never infers it from a delivery result: a host
  that delivers and answers `.unsupported` sends nothing, rather than falling through to a connector. A conversation
  its connector delivers takes images only when that connector's hello lists `images`.
- **A host that knows which turn took a message says so** (`AgentHostChange.delivered`: the request and the turn,
  as Codex does from the `clientUserMessageId` it sent), and the hub follows that turn's reply by the request. A
  message sent through such a host (`AgentHost.reportsDeliveredTurns`) is never matched by its prompt digest or by
  the turn running when the send returns, so a joined draft or two dictations with the same text never send the
  reply to the wrong take; the digest stays for everything else (a host that cannot tell, a new conversation started
  from a host's page, a draft joined through its plugin). A turn named after it ended still gets its reply: while a
  message sent there waits to be named, the hub keeps each ended turn briefly, with its reply text in memory only when
  nothing claimed it. When a turn ends and more than one dictation could be its answer (one already followed and another
  not yet named, or several not yet named), the hub reads the host's own record of that turn once
  (`AgentHost.taken`, Codex's ordered `clientIds`), within `AgentHub.turnRecordBudget`, and reads the reply for the last of
  those dictations the record lists (`AgentHub.settleFromRecord`); a report arriving during that read waits for it, and a conversation disconnected meanwhile gets nothing read. A
  record that cannot be read in time falls back to the dictation already followed, else the first report, so a reply is
  never held longer than the budget. With one candidate the reply is read at once, and the first late report for an ended
  turn claims it. A turn named while another is awaited is followed once it starts or ends, for the message the host
  placed later when two are named into it first. In a hosted
  conversation a turn end claims only the turn it names, and an end without a turn id counts as the turn the hub saw
  start; a connector's turn end carries no turn id and claims the turn awaited, as before. A delivery that stays
  uncertain because the host could not confirm it later is never matched by text and stays uncertain, without a reply
  read aloud.
- **Ultimate is a host whose extension delivers.** One Ultimate process serves one project and many conversations, so
  `UltimateHost` lists them from the project's own files (`UltimateProjects`: the lock names the live process and
  port, `conversations.json` the writable conversations, including coordinator branches, side chats and subagents;
  the root context and lander are excluded), names each conversation's project as its workspace (`AgentHostScan.found`'s `workspaces`, carried as
  `AgentPlace.workspace`: a qualifier that tells two `@ultimate`s apart by project, never a label that names a
  conversation or answers on its own), and declares its extension the delivery route (`.connector`), so every
  dictation takes the bridge `submit` path with its receipts, steering and checks. The extension
  (`Resources/UltimateConnector/`) runs inside each Ultimate process that loads `~/.ultimate/extensions`, and only one
  whose state home is under the installed setup's `projects/` (`served`), so a preview instance stays silent. It
  targets Ultimate 0.1 or later: a Solid page facet (`web.solid.tsx`) and one lifecycle hook, `onOpen`, whose
  disposable stack ends the connection on every release, reload, unload and shutdown; an older Ultimate passes no
  stack, so the extension starts nothing and posts a notice naming the version it needs. An install leaves the folder
  holding only the files this version ships, so an update removes what an older version left behind.
  `make test-ultimate-connector` with `ULTIMATE_CLONE` set runs that checkout's own `scripts/check-extension.ts`
  against the folder, and refuses a checkout whose checker does not check `web.solid.tsx`. It
  observes, never hooks: commits for input, reply and placement records and the task graph for busy, so nothing it
  does sits in a run's path and a crash replays nothing. It submits with `whenBusy: 'steer'` and the bridge request id
  as Ultimate's `requestId`, so a repeated command never submits twice, and emits Ultimate's `user.input` event, which
  Ultimate's automations and keep-warm count as the user's own activity. A receipt waits for the input entry Ultimate
  places; a placement and its entry can arrive in either order and before `submit` returns, so the extension matches
  them from whichever side comes last. A standing agent's handle (`@ultimate`) is its name; any other title is a name
  only when it differs from the title Ultimate's summaries generated. An untitled branch is named by the number
  Ultimate shows for it (`ultimate 61`), given as the listing's explicit name so a title the user gives still wins,
  and as the session's `alias`, so it stays one of the conversation's other names once titled.
  The current sidebar title is also an explicit address after tell, open or check on, even when generated;
  the numbered address remains stable. `UltimateAddress` reads `ultimate`, an optional `conversation` or `session`,
  and one run of number words, whole or grouped, as a conversation number; the whole run is the number or the
  address is unreadable, so a number that names no listed conversation holds whatever follows it. The page reports the visible writable composer, including
  a side chat over its parent, Tab’s new-side-chat mode (`data-side-mode="side"`, delivered through `start` and
  `side-chat/open` so it never falls into `@ultimate`), and the page URL’s `?conversation=` id; a dialog or an editor
  that is not ready holds delivery with its reason. It reacts to
  focus, typing and composer or dialog elements appearing, and re-reads the composer at each heartbeat, so a dialog
  shown by a style change alone is reported within one heartbeat.
  A page in a browser that automation drives (`navigator.webdriver`) or that runs headless never reports focus
  (`automatedBrowser`), so a page an agent opens with a browser tool never becomes the page in front, and while the user
  is in another app no page claims focus and reply checks read no window. A visible browser launched by automation is
  therefore never in front either; the user names the conversation there. A page that hides both signals is not caught;
  the host's address check still keeps a take from the wrong conversation, but its reply is read aloud.
  The host keeps only what the connector reported (conversation, page conversation, whether a page is focused or in
  new-side-chat mode, the hold reason) and pairs it with a window at use time through one async `focusInFront` path:
  it reads the front window's document address off the main actor, revalidates the front window afterward, and matches
  both the project's loopback port and the URL's `?conversation=` parameter against the report (no cached URL across
  reads). The window matched last is the one “open” raises, remembered asynchronously when a page comes to the front so
  it is known before any press. Reply checks read no window while no page claims focus; press checks still read the
  front window so a delayed first focus report arriving after refresh finishes is waited for within the grace window.
  Chromium browsers expose the
  address on the window and Safari a few levels inside it; Firefox exposes none, so a Firefox page is never in front
  (measured 2026-11-20, Chrome, Brave, Safari and Firefox 155). A take checks what is in front through one host focus
  check, including a host's
  new-conversation page, before it waits for anything. It then waits, rather than polling, for a report from the copy
  whose page is in front, a listing that changed a host's conversations, or the press's own host refresh
  (`AgentHub.nextHostReport`, snapshotting report counts before the async check so mid-read reports wake it), until the
  release cutoff, or one front-reading grace after the press while the user
  still speaks; a slow or hung host listing never holds it longer, and a stopped hub ends the wait. Reports about
  other agents and other copies do not wake it.
  Instance paths use the filesystem's canonical path on both sides.
  “Open” switches Ultimate's shared UI state through its loopback `/api/ui` and raises the window last matched, and
  reads as opened only when that window, once raised, still shows this project's page (`UltimateHost.view`): a
  tab closed since then leaves a window that shows something else. A window whose page cannot be read, or that is not
  yet in front after raising, is not the same as one showing something else: it reads as requested and opens nothing,
  since the page was already told to switch and a new tab on every open would pile up. Only with no remembered window,
  or one that positively shows something else, does it open the conversation's page (`UltimateHost.page`, the
  `ultimate.localhost` address Ultimate prints) in the default browser, and read as requested. The page reader keeps
  the address of whatever page the window shows (`UltimateHost.pageURL`), so a window that moved on to another site reads
  as showing something else, not as unreadable. That new page is
  remembered the same way as any other, once it reports from the front, so the next open raises it instead of adding a
  tab. A rename in KeyScribe retitles a branch through the conversations
  extension's `rename` action on the same loopback API (`UltimateHost.rename`); a standing agent's `@name` title is
  fixed in Ultimate, so its rename stays in KeyScribe. The extension takes `label` and shows the name to say in
  `composer.status`, read through its `label` action while the page is visible. Measured against Ultimate `1c5d0565`
  (2026-11-19); `make test-ultimate-live` drives a real headless Ultimate through all of it.
- **A dictation for the conversation in front is typed into it, so it is the user's own prompt.** A connector's own
  prompt runs once the agent is idle (Claude Code queues a plugin's prompt behind the turn; measured on 2.1.325,
  2026-11-14), and only a prompt the user enters is recorded as theirs. So for the conversation in front,
  while its agent works rather than waits on the user, the policy enters it, ahead of steering
  (`AgentDeliveryDecision.enterPromptBox`, eligibility in `AgentHub.takesPromptBox`): the connector adds the text
  to the empty prompt box, never replacing what is there, and the take presses Return
  (`AgentTake.sendFromPromptBox`) only after three checks, in order: the conversation is the one in front; the
  connector answers that the box holds exactly the text and takes the keys (`promptBoxReady`); and, read again
  after that answer, the same conversation is still the one in front
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
  character that keeps a submitted slash from running (measured on 2.1.325, 2026-11-15). The connector puts the same
  character before a submitted `!`, and checks both after leading spaces; that a submitted `!` would otherwise run in
  the shell is not measured (`claude -p` on 2.1.328, 2026-11-19, passed a leading `!` to the model as words). A steered take,
  or a prompt-box take whose Return lands while a turn runs, follows only a turn that read it: the running turn once
  the connector reports it absorbed (for Claude Code, the queued input a later model step carries, read from the
  conversation and reported as `absorbed`), or the turn the message starts when the running one ended
  first, matched by its prompt digest (`followSteer`). It never claims a turn that did not read it, so its reply is
  heard once. A turn that takes in several dictations, whether one started it and others joined it or all joined it,
  answers the last one it took in (`AgentHub.follow`), for every agent and whatever order their reports arrive in:
  the user asked that one last, so its answer is the one they wait for. The dictation that opened the turn never takes
  the reply from one taken in later, however late its receipt arrives; takes in a running turn are ordered by the
  agent's own reports of taking them in: a connector's `absorbed`, which names the request it took (`request`, the
  submit's id), so two takes with the same words are never confused; or a host's own record of the turn, whose position
  for each message (Codex's `clientIds`, as `AgentHostChange.delivered`'s `position`) orders them however late its
  report arrives. A take's words are matched only for an `absorbed` from a connector older than `request`, oldest
  waiting take first. A message for that conversation
  already held or still being handed off keeps the hold; an attached image, a connector without `box`, a
  conversation not confirmed in front, or text the box will not take goes to the agent as a steer when its
  connector lists `steer`, and otherwise keeps the hold.
- **A dictation for the conversation in front joins text already in its prompt box.** Only the take knows the
  conversation is in front, and asking costs time on every take, so it asks (`AgentTake.deliver`) only once
  there is a draft to join: a connector that lists `merge` (`AgentHub.joinsDrafts`) is sent the take without it
  first, and only a `draft` refusal, which the connector decides from the box it reads anyway, has the take ask
  what is in front and send it again with `merge`. bb's plugin reports the draft ahead of time, so for bb the take
  asks only while the hub knows the thread's box has text (`AgentHub.showsDraft`). A conversation not in front
  keeps the `draft` refusal, since text left in a box nobody is looking at may be stale. Each connector joins it the way its agent
  sends typed text, and none joins when the dictation or the draft starts with `/` or `!` after leading spaces
  (`runsAsCommand`, the same in each), since the send would run it with the other as its arguments. The joined
  text is built the same way in each, with no space after an empty draft or one ending in whitespace. Claude
  Code's appends to the box (`joinDraft`) and answers `joined`, or `joinedMidTurn` when its own turn runs, so the
  connector, not the hub, decides whether the take follows an `absorbed` turn; the take sends either with Return
  through `sendFromPromptBox`, as it does a filled box. Pi's has no call that sends its editor, so it reads the
  editor, clears it and sends the joined text in one synchronous block after its last wait, so no key lands
  between them; it never joins where a send could fail after the clear (no terminal of its own, no model,
  compacting), and puts the draft back, unless the user typed meanwhile, when the send throws or rejects or when
  Pi has not taken the message by its receipt deadline, since Pi's extension `sendUserMessage` reports most later
  failures only to Pi's own error display. A send Pi takes after that deadline clears the draft put back again,
  only while the editor still holds exactly that text, so it is never sent twice. A joined take reads “Sent to docs with the text in its prompt box” (`AgentReceipt.sentWithDraft`) and its
  Delivery line says so (`AgentDelivery.withDraft`). bb's goes through its plugin (below). A connector filed under
  a hosted conversation is never asked: only the host's own plugin joins there (`AgentHub.hostOwned`).
- **Claude Code's busy takes wait for the turn to end and go in as the user's own prompt.** Claude Code gives a plugin
  no way to put the user's words into a running turn: `$.prompt.submit` waits behind the turn, and what a plugin
  appends with `$.session.append` is held as that plugin's note (`plugin_note`) and reaches the model framed as
  “Note from the … plugin, not from the user” (read from the code of 2.1.326 and 2.1.330, 2026-11-23). In
  downstream's live run on 2.1.326 (reported 2026-11-23) the model ignored such a row, saying it came from a tool result rather than from
  the user. The earlier measurement that a dictated approval appended this way was taken as the user's, idle and
  mid-turn, was made on 2.1.325, before that run. So the connector lists no `steer`, and every busy take waits in
  the hub's queue (`AgentOutbox`): a take for a working conversation that is not in front reads “Queued for …”, and
  a `submit` that still meets a running turn (one that raced the turn's start, a `/` or `!` the box must not take,
  or text the box will not take) is refused as `working`, which the hub queues the same way, back ahead of takes
  said after it (`AgentOutbox.send` with `ahead`). The refusal leaves the connector before that turn's
  `turnComplete` does, so the hub never misses the end it waits for; a fill that fails after the turn ended submits
  instead. The queue releases one take per turn end, oldest first. The user's Esc (`turnComplete` with reason
  `aborted`) or a message the user sent meanwhile (`typed`) keeps a queued take for review rather than sending it
  (`needsReview`, read as “didn't take that: its last turn was stopped” or “you sent it a message since”). A draft
  in the box refuses a take as `draft`, or joins it for the conversation in front, as at idle. Nothing is added to
  the running turn, and the connector holds nothing. Because a Claude Code turn can run for minutes, that review
  rule now covers every take to a busy Claude Code conversation that is not in front: typing in it or pressing Esc
  before the turn ends keeps the take rather than sending it after. Only a Claude Code connector from before this
  rule still reports a held take late as `filled` or `added`; the hub's `leftInBox`, `onLeftInPromptBox`
  (`AgentTake.sendLeftInPromptBox`) and those two cases of `refuseSteered` serve nothing else. An app update
  reinstalls the connector, but a Claude Code session keeps the one it loaded until it restarts, so they can go
  once a release after this one has shipped; the other late outcomes of `refuseSteered` still serve Pi's steered
  takes.
- **Claude Code's connector takes its facts from Claude Code's own events, not its classic hooks.** An organization's
  plugin in the `prepend` tier may continue an event past every personal plugin (`next.to`), and Claude Code then tells
  the model, in every session, that the personal hook was skipped; one did so for `classic.SessionStart`,
  `classic.UserPromptSubmit` and `prompt.attachment` (2.1.329, 2026-11-20), and for `session.append`
  (2.1.330). The connector hooks only the events `managed-plugin.test.ts` lists, so adding one a managed plugin
  could pass by is a deliberate choice. So the session is `$.session.id()` read when
  the poll loop starts and after every `command.run`, since a `/clear`, `/resume` or `/branch` ends the old session and
  switches the id inside its own command (measured on 2.1.329: the id is still the old one after `session.end`'s
  `next`, and the new one after the command's); the next prompt reads it again for a switch that came another way. A
  session is fresh when its conversation holds no rows yet (`$.session.messages`), as a launch or `/clear` leaves it,
  and a resumed or branched one is not; its turn is known idle when it is fresh or when a command just switched to it,
  and unknown after a plugin reload. Mid-turn input is read when a main-loop model step starts (`turn.step`), and
  only while an input noted since the turn began (`prompt.submit` carrying the turn's id) is still unmatched, so a
  turn nobody typed into reads nothing. The hub needs the report during the turn, not at its end: an `absorbed` take
  is followed from then on, so an approval the agent asks for afterwards is announced for it. The read is the
  conversation as the model gets it (`$.session.messages` with `as: 'api'`, since the plain read leaves out the
  `queued_command` rows), awaited for at most `stepReadLimit`; one that takes longer lets the step go on and is
  dropped, as is one that finishes after its session or turn changed. On 2.1.330 (read from its code, 2026-11-23)
  `as: 'api'` converts the whole conversation and only then applies `last`, so a read costs more as the
  conversation grows, which is why it is gated and bounded; `last: 1` starts at the last user row that carries no
  tool result, normally the turn's opening prompt, so the read spans the turn. Queued input is merged into the user
  row that carries the step's tool results, one text block per input in its origin's frame, so the user text after
  the last assistant message is what that step newly carries (`stepTail`). The turn's first step reads nothing
  when no assistant message precedes it, since that tail is the opening prompt. A tail read before (a retried step)
  is skipped (`readTail`). Input that matches nothing noted counts as someone else's only when it carries Claude
  Code's frame for queued typing (`queuedTyping`, copied from 2.1.330; a Claude Code that rewords it needs it copied
  again). Inputs are matched in the order they were
  submitted (`takeQueued`): Claude Code hands queued input to the model in submit order, and a prompt-box
  dictation joins that order only when its Return is submitted, and only the newest fill can own a submission, so a
  message with the same words queued earlier, or a fill left unsent and replaced, is never reported as the dictation. It
  reports no title, since Claude Code gives one only to classic hooks: a name the user sets reaches the hub through
  Claude Code's session registry, which it watches, and a generated title through the transcript. `ClaudeDiscovery`
  alone keeps which conversations to look at: each turn end watches that conversation for `ClaudeDiscovery.titleWatch`,
  and each scan takes a snapshot of the watches due (at most every `ClaudeDiscovery.titleRecheck`) and reads only those
  transcripts that changed, so a title written just after the end still arrives, no scan can drop a watch another
  turn end added, and the title cache's lock is never taken on the main actor. `classic.Elicitation` is the one classic hook left: Claude Code reports an MCP server's request
  for input nowhere else, it runs only when one asks, and it only holds a prompt-box Return during the moment the dialog
  may not be drawn yet, which the box's own readiness check covers once it is. `managed-plugin.test.ts` loads a
  `prepend` plugin that passes those events by.
- **A steer confirmed and then not delivered is reported late, against its take.** A connector that lists `steer`
  confirms a take before the agent reads it, so one that does not go through after all is reported with a late
  `refused` for the same request (`draft`, `filled`, `added`, `stopped`, or the agent's own reason), which the hub
  turns into a late notice for the take it had already reported sent (`AgentHub.refuseSteered`). A Claude Code
  connector from before it stopped listing `steer` still does this until its plugin reloads, leaving takes in the
  prompt box after Esc; takes left in one box are one press: the hub joins every later fill for that conversation
  to the press already under way and settles them all with its outcome (`AgentHub.leftInBox`), and
  `AgentTake.sendLeftInPromptBox` presses Return through the same in-front checks as any prompt-box take, never
  while a recording is open. Like a steer Pi has accepted, a confirmed take is the agent's, not a queued command: a
  lost connection to the app does not cancel it. The take's History entry follows it: the app keeps tracking a sent
  take while the hub says it can still change (`AgentHub.awaitsLateOutcome`), and the hub forgets it, through
  `onForget`, once a turn reads it, its conversation goes, or it is the oldest past the bound. A late notice for a
  hub that has restarted since is not recognized, so History keeps “Sent” then.
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
  connected, offers Disconnect like any connected conversation, and Settings names it by the host. While its
  connector reports turns, a turn's start or end shows at once rather than at the host's next list
  (`HostDiscovery.withPrompts`), until a host list read after that report says otherwise. Only a connector whose
  hello says it reports turns (`notify` and `readiness`) moves the row, and a turn that ends while a prompt was open
  reads as idle. Its
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
- **A host that names what each turn took has one attribution source: the turn's end.** Its plugin advertises
  `accepted` and lists, in `turnComplete`'s `accepted`, every message the turn took, in order, from the host's own
  record of the turn: each message's digest and the time the host recorded it. For such a conversation nothing binds
  a dictation to a turn earlier: a turn's start, or a dictation delivered into a running turn, only proves arrival (a
  matching start reports an unclear delivery as sent) and lets an approval or question in that turn be described
  (`AgentHub.attendHosted`). At the end each listed message takes the oldest waiting dictation that carries it
  (`AgentHub.claim`, `HostFollow.carries`): the same digest, recorded while that dictation was being sent (from the
  moment the send began to the moment the host answered, within `AgentHub.sendSlack`; a send the host queued has no
  end), and a wait that had not run out when the turn started. So the same words typed in the host, before the
  dictation or after its turn ended, never take its reply; two dictations with the same text are each read for the
  turn that took them; a long turn still takes a dictation it took at its start. The reply is read once, for the
  dictation the turn took last, or for none when the agent's read-aloud tool asked for it; a turn that took none
  leaves them waiting. The host's send command gives no request id to match on (bb 0.49's `thread tell` answers only
  `sent` or `queued`, and records no sender for a message it sends; checked 2026-11-19), so the time the host recorded is the identity
  available. The window rests on where bb stamps that time (read from bb 0.49's server source, 2026-11-19): a message
  it sends at once is recorded inside the send request, before it answers; one it queues is recorded when it
  dispatches it, which is why a queued send has no end; a retry keeps its original's time (`retryOf`, followed by
  the plugin); and it emits `thread.idle` only after the turn's `turn/completed` is stored, so the record is complete
  when the plugin asks. Each turn end logs how long after its send began bb recorded each message it claimed, which is
  the measurement to check when the window is in doubt: 0.25 to 0.29 s, both into an idle thread and steered into a
  running turn (bb 0.49, `thread tell --mode auto`, measured 2026-11-19). A list that is absent (the host could not give its record)
  and one that is empty mean different things: an empty list takes nothing, while an absent one falls back to the
  digest of the prompt the turn started with plus every dictation the host took at once (not queued, not answered
  unclearly) after the turn started (`AgentHub.claimSteered`), which is a guess, and the log says the record was
  missing. Part of the guess: a dictation sent after the host ended the turn but before that end reached the app
  (at most the plugin's deadline for the record) is taken for the turn that ended, not the one it started.
  A turn whose record is present and empty is one the agent started without a message: it carries on the work of a
  turn before it, such as reporting a background command that finished, or answering a message bb recorded for the
  running turn that the agent took in only after it ended (seen with Claude Code in bb 0.49, 2026-11-19). Such a turn
  is read for the dictation the conversation's last dictated turn took last (`AgentHub.continuing`), so each
  dictation's answer is heard however many turns the agent takes to give it. A turn that takes any other message
  (typed, or from another agent or bb itself) or a turn without its record ends that, and none is read once
  `AgentHub.continuationWindow` has passed since that dictated turn ended, however often the agent wakes itself, so a
  typed request's follow-ups and a scheduled wake-up long after are never read as the dictation's. The record cannot
  say which earlier request such a turn carries on, so work started by a typed message that finishes inside the
  window after a dictated turn is read as that dictation's. The take's History entry keeps the latest reply read
  for it.
- **Agents and setups are isolated at the bridge.** Each enrolled setup has its own installation id
  (`ConnectorSetups`), and retiring one installation's connectors leaves every other setup's and agent's
  sessions connected. Inside the app a conversation id is
  `agent:nativeId` (`AgentSessionID`); the bridge is the only place that translates, namespacing every
  event by the hello's agent and handing connectors their native id back, so two agents may reuse an id
  and never meet. Saved names carry the namespaced key; a legacy key gets the agent the composition root
  names. A connector advertises what it can do
  on its hello (`features`); a missing feature reads as an outdated connector only when the connector that said
  hello is not the one the app bundles for that agent, and as unsupported otherwise. `AgentHub.runsOlderConnector`
  is the one test of that, for focus, the footer's update step and Settings alike. It compares the hello's
  `codeVersion`, which the installer writes into the connector's code (`builtVersion`), never the settings file's
  version, which an older connector reads again after an update; a hello without `codeVersion` is from before the
  field and so older, and a host's own connector is never compared.
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
  partial, never empty, and only when the process's own name is the agent's (a wrapped `.pi-wrapped` counts);
  a candidate whose process could not be read stays listed. The process table is listed once for every agent's
  discovery and reused until it ages out (`AgentProcessTable`), so the liveness tick never sweeps it per agent.
- **An agent process is recognized by what it runs, never by a fixed process name.** `AgentProcesses.Rule.launch`
  matches the program (its name with wrapper dots and `-wrapped` removed, or an install path the rule names) or, for a
  known runtime or shell (`Rule.runtimes`), only the script in its interpreter slot (the first argument that is not a
  flag, after a subcommand such as `run`), and only when it is a regular file that is the agent's executable or lies in
  its install path. A program that merely opens or names the agent's file (an editor, a pager) is not the agent. A
  wrapper script run by a shell that stays running is not the session when any process below it runs the agent, however
  many wrappers or other programs sit between: that process is, so its pid and environment (a folder variable the script
  exports) are the ones used. The wrappers are found from one snapshot of the matches, so the result never depends on
  the order processes are listed in. Paths behind a
  privacy prompt or on another volume are never looked at (`AgentProcesses.mayLookAt`), so a scan cannot raise a
  permission prompt or wait on a mount; a symlink outside them that leads into them is resolved, which is the one
  remaining way a scan could touch one. `AgentProcessLister` reads every process of the user in one
  `KERN_PROC_UID` call and reads arguments only for processes it has not seen (keyed by pid, start time and name),
  outside its lock, so the steady cost stays near the old name-filtered scan. Measured on an M5 Pro with 762 user processes
  (2026-11-17): the name-filtered scan 0.6 ms, arguments for every process about 18 ms with one sysctl per process
  and 6 ms after the bulk listing, the bulk listing alone 0.1 ms. A matched process reports the command it runs
  (`AgentCandidate.tool`, through its wrapper when one sits beside it) and its runtime. A process started by an
  agent is still not a session. Processes that resemble an agent but do not match are kept, by path and name only,
  for Settings' Copy Details, after the matched ones, as program paths and argument paths of existing files only.
- **A connector that runs no program never searches for one** (`AgentConnector.findTool` answers nil, as for Ultimate's
  extension, which only writes files): Settings installs, checks and removes it against its setup folder alone, never
  shows it as not found, and Copy Details leaves out the program search.
- **A tool is chosen in one order and must answer.** `ToolEnvironment.search` (order in `ToolSearch.places`): a
  command the user chose for the folder (stored on its enrollment, and then the only place looked), a running
  conversation's command for that folder, the login shell's `PATH`, the app's `PATH`, the usual folders. The login
  shell (`ShellEnvironment`) runs only while the Agent feature is on: once after the feature has been on for a quiet
  period (never at launch), and then not while a take is in progress (`ToolEnvironment.waitWhile`), so a prompt an rc
  file raises cannot take focus mid-dictation; on Settings refresh; and after a miss, throttled. A Settings refresh or
  miss while the user dictates is not held back: the user is in Settings, or acting on a missing tool, then. It runs off the main thread in its own
  process group (a timeout kills the group, so nothing an rc file started outlives it), with stdin closed, stderr
  dropped, an output cap and per-run markers. It keeps only `PATH` and the folder variables the integrations declare
  (`AgentIntegrations.folderVariables`, fixed when the feature turns on), and a failed run keeps the last good answer.
  Nothing waits for it: Settings shows rows from the answer in hand, and observers (`ToolEnvironment.observe`) refresh
  Settings and re-run connector maintenance when the answer changes. The command then runs with its own folder (and its runtime's) ahead of the shell's
  `PATH`. Working means `--version` printed a version in time (`ToolCheck`); each failure keeps its own reason
  (timed out, exit code, signal, no version, could not start), and a result is cached until the file changes; a failed one is
  also forgotten on each Settings refresh. Output on the error stream is kept for `--version`, since that is where a
  missing runtime says so. A connector's folder variable from the shell lists that folder for discovery and Settings; it is never
  installed into.
- **bb is a host reached through its own `bb` command** (`BBHost`). A bb build is found from what it publishes, never
  from a fixed bundle id, app name or folder (`BBBuildFinder`, `BBBuilds`): a data folder holds the command bb writes
  (`bin/bb`) and its runtime record or thread storage, and is the usual folder, a hidden folder in the home folder,
  the `BB_DATA_DIR` a running app declares in its launch environment, the `BB_DATA_DIR` of the user's login shell, or
  a folder the user adds that passes the same check (`BBBuildFinder.isDataFolder`). The app it runs from is, in
  order: a running app whose launch environment's `BB_DATA_DIR` names the folder; the app the runtime record's entry
  path or the command's runtime path names, while it runs; an app seen naming the folder since launch that still does,
  so a copy keeps its name after it quits; else that recorded app. Ties go by path. A server bb started outside any
  app can write both records and an app then attaches to it; no app is then guessed from what an app bundle contains,
  since a wrapper can hand bb its folder at launch without declaring it, and a wrong guess would send words to another
  folder's thread. A closed folder no app is known to use asks for the copy that uses it to be opened, and says that
  an open copy that doesn't name the folder can't be matched to it; it never asks the user to edit an app's
  `Info.plist`, which would break the app's signature. The running process that is a copy's app, which Open raises
  and reopens, is first the app that owns the process its trusted runtime record names
  (`BBBuilds.process`, `BBBuildFinder.runningApp`), since two copies can run from one app bundle with different data
  folders and then share its location too. Otherwise that app's location, not its bundle
  id, says whether it is open and which app in front is it, since copies of one app share a bundle id; any running
  app whose launch environment names the folder also counts as it being open. An app in front whose launch
  environment names a folder is that folder's copy, even when another app also names it. When the recorded location is stale,
  the data folder the running app uses (its launch environment's `BB_DATA_DIR`, else the usual folder) decides,
  never the bundle id alone, so a copy without the plugin is never taken for another copy of the same app that has
  it. Each copy keeps its own last report of what it shows (`AgentHub` keys those by host and data folder), so
  switching between copies needs no new report. The app's file name, as Finder shows it, is what Settings and every message call it. A take with
  nothing in front while a copy of bb is the app in front says why, from that copy's own data folder
  (`AgentHub.hostCopyNotReadyInFront`), naming the copy, with **Open Agent Settings**. An app whose launch environment
  names a bb data folder counts as a copy even when that folder is not one bb has set up; that take says the folder
  isn't set up and offers no Settings button, since Settings lists only set-up folders. Otherwise the plugin is missing when
  the copy's folder is not enrolled; otherwise the copy is not connected, and Agent settings, which checks the
  plugin when it opens, shows why. A connected copy names the first step still missing, in the order a send needs
  them: Accessibility is off, so its window can't be read (with **Open Accessibility Settings**); its window in front
  can't be read; it hasn't shown a conversation (a page with no thread, such as settings, or a window its plugin has
  not reported yet: the plugin reports on load, on focus and blur, and every few seconds while visible, so this
  passes on its own); it shows a thread its list doesn't have yet; or it shows its New thread page but its plugin can't
  start a conversation. Only the plugin steps offer **Open Agent Settings** (`AgentTake.action(for:mode:)`). The step is
  read once, when the take starts, and says why that take found nothing; each line says what to do before trying
  again, since the state can change while the user speaks. The take never checks the plugin itself, since enrollment outlives a failed
  install and a removal inside bb and only that check could tell them apart. Telling which copy is in front uses
  the front app's own details, never its window. Finding the thread in front reads bb's focused window once and
  hands that reading to `AgentHost.front`; which copy owns that window is decided from the app in front first, so a
  copy whose app opened after its folder was last described is still found, and a send reads it again right before sending, never reusing it. Each enrolled data folder is its own instance:
  its threads are keyed by that folder, and every call for them runs that folder's own command with that folder as
  `BB_DATA_DIR` and a fixed environment that turns bb's telemetry off, never the app's own. The one value taken from
  the folder is the server its runtime record names (`serverUrl`), as `BB_SERVER_URL`, only when that server is on this
  Mac (http or https) and only while the process that wrote the record still runs (`BBBuilds.environment`): the record's
  process must be the user's own and must have started no later than the record's `startedAt`, so a process id reused
  after a crash, which starts later, or one belonging to another user, never counts. bb's command
  otherwise goes to the default port, which for a copy started on another port is a different copy's server. A record
  left behind by a crash names a port another copy may now hold, so it is ignored while its process is gone, and bb's
  command finds its server as bb's own `bin/bb` would. A record without `startedAt` is never trusted. bb 0.49.0's record carries `pid`, `serverUrl` and `startedAt`
  (ISO 8601 with milliseconds), and its process started under a second before that time (measured on 2026-11-17). A failed match for an app that names a folder is never cached, so a folder set up while
  that app is in front is found on the next take. When an app that is one of bb's copies launches or quits, the host
  says its list changed (`AgentHost.watch`), and the hub scans it again at once instead of at its next interval. A
  copy that just launched may not be serving yet, so until its folder lists the host asks again a bounded number of
  times a few seconds apart; the other copies' listings never hold it back. The hub stops watching when it stops. Each
  app path's resolved form is kept for the life of the app, so a symlink retargeted while it runs keeps its old
  answer until relaunch. A build that is closed or
  could not be read keeps the threads it last listed, as Last seen, while the others are listed fresh
  (`AgentHostScan.found`'s `carried`); only when no build could be read is the list unreadable, and then its problem
  names a closed build whose threads were listed this run before one that never had any. A closed build is
  not a problem while another build lists, since a copy the user is not running is not a fault; a build that could
  not list is, and its problem names that build. A carried thread is not counted as available in Settings, since
  its build cannot be reached. Delivery uses `--mode auto`, which steers a
  running turn and starts one when the thread is idle, as typing in bb does. The hub holds nothing back for an open
  approval: bb queues the message itself and answers `queued` (measured with bb 0.49.0 on 2026-11-15, Claude Code in
  a thread stopped on a command approval). The approval stayed open, the message sat in bb's queue as
  `waitingOn: interaction`, and once the approval was denied bb delivered it into the same turn. If a later bb
  steers into an open approval instead, the hub must hold the take as it does for a terminal agent. A queued
  answer's receipt names what the thread waits on, from the thread's state in bb's list or, once the plugin has
  reported the prompt, from that prompt's kind (`AgentLiveState.named(by:)`, as for any dialog: a confirm is an
  approval, a select, input or editor a question, anything else a dialog). bb's `sent` reads as sent, and a
  dictation it steers into a running turn follows that turn's reply, `queued` as
  queued, its error envelope as refused in plain words, and anything else as uncertain; bb's error code goes to
  the log as public and its message as private, since a message could echo what was sent. Open only asks:
  bb's answer counts the clients it broadcast to, not a window that showed the thread, so it reads as requested, and bb is brought forward only when some client took it and the open is
  still wanted. On macOS bb keeps running with every window closed and makes a new one only when reopened, as a Dock
  click does (read from bb 0.49's desktop source, 2026-11-21), so an open first checks that copy's app for a window (`BBBuildFinder.windows`; bb's answer counts every
  client, not windows: 4 with one window open and 3 once it closed, measured on bb 0.50.1, 2026-11-21). A window on
  screen is used as it is. A window that exists but is not on screen, minimized or on another Space, is brought back
  rather than treated as closed: the one window bb lists first, through the same window focus voice commands use
  (`BBBuildFinder.restore`), which checks that the open is still wanted before each step. The open goes ahead even if
  it is still not on screen after the wait. With no window at all it reopens that copy (`BBBuildFinder.reopen`) and
  waits for its window before asking. When bb does not say which windows it has (Accessibility unanswered or not
  granted), that stays its own state: the copy is reopened the same way, and if no window appears the open says bb
  did not say which windows it has, not that it has none. The wait polls only the on-screen window list. The app all of these act on is the first regular app above the process bb's runtime record names
  (`BBBuildFinder.appServing`), never a helper process, which has a bundle id of its own. The reopen goes through
  `open -a` with the copy's own location: `NSWorkspace.openApplication` picks a running app by bundle id, so with two
  copies of bb running it reopened the other one. An open bb does not take says
  why (`AgentHostOpen.refused`, with the reason `BBHost.open` found), and that reason is the HUD line and the History
  summary, never “Nothing showing … was brought forward”.
  Open has its own deadline, which each host states (`AgentHost.openDeadline`) from the steps its open takes, so the
  hub's cutoff never comes before a step the host is still allowed to finish; bb's adds its window wait to its
  command's timeout. A host that refuses an open says why and is not followed by focusing a terminal: only a
  conversation with a process is focused that way, and host conversations have none.
  In-front comes from bb's plugin (below), since bb's command reports no focused thread. While neither bb's app runs nor the process its runtime record names serves on this Mac
  (`BBBuilds.serves`), its command is not run at all; a server left running after its app quits still lists, takes
  messages and renames, but Open needs a window, so it waits for the app. The command never starts bb's server either (it fails at once, measured with bb
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
  switches, and only when the user picks that button (`AgentConnector.undoesOnUninstall`). A location that is not a thread of an enrolled build's data folder is never passed to any command. A
  list longer than `HostCLI`'s output cap reads as unreadable, not as the part that fit. An agent bb started
  is placed in its thread by `BB_THREAD_ID` together with `BB_THREAD_STORAGE`, which must be that thread's
  folder in an enrolled build's data folder (`BBThreads.thread(in:instance:)`); bb passes the dictated text to the agent
  unchanged, so its digest matches (checked with Claude Code in bb 0.49.0, 2026-11-14), while bb's own
  messages to a parent thread arrive as turns of their own and are never followed.
- **One conversation per session id.** A discovery can list a session twice for a moment, for example while bb
  restarts a thread's Claude Code and the old process has not exited, so the hub keeps only the newest-started
  entry for each id as it assembles the list (`AgentHub.newestOfEach`), before anything downstream builds a
  dictionary keyed by conversation.
- **bb's plugin is a connector for every bb thread** (`BBPluginConnector`, sources in `Resources/BBPlugin`). It is
  installed like a connector, by the consent sheet's enrollment for a bb build's data folder, each build on its own,
  and bb is on exactly while any of those setups is enrolled, read from the enrollment itself, never copied into settings
  (`AgentsSettingsModel.isTurnedOn`; the hub rescans on every enrollment change,
  `ConnectorSetupRegistry.onChange`). Enrollment, not bb's report, decides it: a failed install or a plugin removed
  inside bb keeps bb on, reads Not installed, and offers Reinstall without asking again, and an enrolled setup always
  offers Uninstall. A revocation that could not be saved still holds in memory and is written before any reload reads the
  file (`ConnectorSetupRegistry.reload`); a grant that could not be saved changes nothing, so the file stays in
  charge. An unreadable setups file keeps the enrollment already loaded; at a launch that finds it unreadable, nothing is
  loaded yet, so bb reads as off until the file is fixed, as every connector is refused then. KeyScribe writes its sources and settings into its own support folder,
  one copy per build (the usual folder's keeps `bb-plugin`, so an existing install stays where it is), then has that
  build's bb install it from there (`bb plugin install`, which builds a path source itself and runs `server.ts`
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
  thread's history that is not still queued, and none for a row bb itself queued (bb emits `message.dispatched` only
  for a row it queued, never for a message sent at once or steered into a running turn, so that prompt is a guess);
  a `turnComplete` only for a turn
  it saw start or found running when it loaded, naming the sender bb records for a row an agent, an automation or bb
  itself queued (never for one a plugin queued, since that can be the user's own dictation), and the newest row the
  running turn took in when another was dispatched while it ran; a note bb itself dispatches never replaces a message
  already named for that turn or the next one. Its `turnComplete` also lists, as `accepted`, the
  digest of every message bb accepted into the turn that ended, read from bb's own record of that turn
  (`client/turn/requested` joined to `turn/input/accepted` by request id, `acceptedInEndedTurn`), each with the time bb
  recorded its request (a retry's original request's, `retryOfRequestId` in bb 0.49's record), marked `host` when bb
  wrote it itself (its `[bb system]` notes, such as a child thread finishing, `initiator: system`), and a joined draft
  named by the dictation it carried; a record
  bb cannot give within its deadline, or one with a message it cannot place (no request to join, no number for its
  time), sends no list rather than an empty or shorter one. A message with no text (an image alone) is placed and
  listed, and matches no dictation. A message bb or another thread's agent sends is recorded the same way as the
  user's (read from bb 0.49's server source, 2026-11-19). Delivery stays bb's command. bb's thread events carry no turn id, so the turn that ended
  is chosen by when it started: the newest one bb records as completed (or, for a failed turn, completed or started)
  that started no earlier than the plugin saw this turn begin, give or take a moment; if none did, no list is sent
  rather than the previous turn's. The record is asked for the moment the turn ends, not after earlier reports land.
  A reply's mention of a thread (bb's `@thread:<id>`, with or without `#msg=`) is sent as the name the app gave that
  thread, or "another thread" when it has none (`spokenMentions`), so an id is never read out letter by letter.
  While the plugin is live for a thread it holds that thread: an agent's own connector there is sent back and not
  filed. The plugin itself is never filed; only an agent is. Whether the plugin holds is read from its own
  connection wherever it is asked (`AgentHub.pluginHolds`), the hand-off of the agent's read-aloud request included,
  and afresh on every pass, never remembered: a thread whose plugin holds it but
  has an agent filed is unfiled and the agent asked to say hello again, which stops once the filing is gone, and a
  thread whose plugin does not hold it and has nothing filed has its agent asked again, which stops once the agent
  files. So a thread never reports its turns twice, whatever order the plugin goes silent, the agent says hello and
  the plugin is heard from again. It lists bb's threads page by page, and a thread it had not listed says hello as
  soon as bb reports it working. Events the app cannot take are dropped, never replayed.
- **One connector holds a conversation, and everything about it comes from that connector.** What a connector can
  do is kept by its instance, never by the session id a plugin and an agent filed under it share
  (`AgentHub.holder(of:)`): the host's plugin while its own instance is live, else the agent's live connector, else
  the one that said hello last. A hello replaces the earlier instance of the same role in that conversation, since a
  reconnecting connector comes back as a new instance, but a plugin that is only silent keeps its place, since it
  polls again without a new hello. The holder's features decide every capability (draft joining, prompt digests,
  labels, focus, steer, checks, images, starts), its version alone is compared with the bundled one, and every
  command for the conversation goes to its instance while it is live (`AgentHub.send`). Liveness is that instance's
  (`AgentTransport.isLive(instance:)`), never the conversation's, which another connector may keep up. The send line
  logs the plugin's state: no hello, not connected, or holding with or without draft joining.
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
- **bb's plugin stands in for `/keyscribe` in a bb thread.** bb lets a plugin add no `/` command of its own (those
  come from skills and the agent's own commands, and both send the agent a message), so the window half registers two
  message-box commands, in the `+` menu and bb's command palette: read this thread's reply aloud, and don't. Each asks
  the server half over bb's plugin RPC (`readAloud`), which sends `notify` on or off for the composer's own thread
  exactly as the tool does, and shows the terminal command's answer (`commandAnswer`) in a popup in that message box,
  since a plugin's command can show nothing else. Only the latest request in a message box shows its answer
  (`ComposerAnswers`), so a slow answer to an earlier choice never replaces a newer one, and answers are kept for a
  bounded number of message boxes.
- **bb's plugin joins a dictation to the message box of the thread in front.** bb's command cannot see a draft,
  which lives in each window, so each window also reports whether the thread it shows has text in its message
  box, and the plugin's `shown` carries it as `draft`. Only for the conversation in front with `draft` does the
  hub first send the plugin a `submit` with `merge`, waiting at most its receipt timeout; an empty box, the common
  case, goes straight to bb's command. The server half asks the window it reports as showing that thread over
  bb's realtime channel. The window must take it up (the `composing` RPC) within a second, before it touches the
  box, or the plugin answers `empty` and the hub delivers through bb's command, since nothing went in; a window
  that takes it up late is told not to start. That window's overlay (`composeInto`) adds the dictation at the end
  of that thread's one message box and sends it with the box's own send, steering a running turn as `--mode
  auto` does, and answers through the `composed` RPC. Empty boxes answer `empty`; two boxes for the thread, one
  with text, a draft that starts with `/` or `!`, or a box bb would not send answer `draft`; a send bb refused after
  the dictation went in answers `added`. A window that took it up and never answered leaves it uncertain, never
  sent again through the command, since the box may already have sent it. The plugin remembers each joined
  message's text, without its surrounding whitespace, and names the turn it starts by the dictation's digest, so
  its reply is followed.
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
- **A host's new-conversation page is a recipient only for a take that names none.** bb's window half also reports
  whether its window shows the new-thread page (no thread, a `new-thread` composer on screen), and the plugin's
  `shown` says `newConversation` instead of a thread, carried on any connected member. Besides its threads, the
  plugin always says hello as one member under its host's new-conversation key (`new conversation` at its
  instance), so the page is reported, and `start` reaches the plugin, in a bb with no thread yet. No host lists that
  key, so it never becomes a conversation, and its hello never asks the host for its list. The hub keeps that carrier
  per host like the shown thread, forgets it on Disconnect, and puts the page in front (`AgentHub.newConversationInFront`)
  only while the carrier is live, its hello lists `start`, and the host's own window check
  (`AgentHost.focusedWindow`) finds the host's app in front with a window focused. The take captures it at the
  press under the same input and same-window rules as a thread (`agentNewConversation`, separate from
  `agentFocus`, so rename, `check on` and go back never act on a page), and it is used only when the take would
  otherwise be held as `nothingFocused`. Delivery reads the page again right before sending and sends only when it
  is the same app and window; the plugin checks its front window still shows the page before typing. It is a
  `start` command, never bb's command, and its answers stay distinct: `gone` (page left; nothing sent), `filled` or
  `added` (bb refused before sending: its box was blocked, or it rejected the box as empty, which the plugin
  retries for a moment while bb still says the box can send, since that is bb not yet having caught up with the
  typed words; "empty" is recognized by the reason bb gave the box before anything was typed, not by its wording; the words wait in the box, and the HUD gives bb's own reason when the refusal's `detail` carries
  one, else says to press Return), `unclear` (any failure whose error does not prove nothing was sent, which only bb's
  empty-draft refusal or the exact reason bb gave for a box blocked just before the send do; what the box shows
  afterwards proves nothing; never retried, and read like no answer), `draft`, and anything else as could not start; no answer is uncertain. A join into a
  thread's draft answers `unclear` the same way, and it is never sent again through bb's command. A new conversation's dictation is followed into the first
  turn, with the dictation's digest, of a conversation in the same copy of that host (its data folder) that was not
  listed or disconnected when it
  was sent (`AgentHub.startFollows`, bounded like host follows), within `AgentHub.hostTurnWait`. The plugin reports
  a turn that started before its thread's hello landed once the hello does, and never one that ended first.
- **Codex is a host reached through its shared app server** (`CodexHost`, `CodexDaemonClient`). Each enrolled Codex
  home (`~/.codex`, or the folder `CODEX_HOME` names) is its own instance. KeyScribe connects as a local client to
  that home's control socket (`app-server-control/app-server-control.sock`) and never starts, restarts or stops the
  server; a socket that does not answer reads as the app server not running (`CodexHost.daemonDown`), never as no
  conversations. Callers that need the server at once share one connection attempt per home, so a scan and a send
  started together never cancel each other. The full list (`thread/loaded/list` and a `thread/read` per thread) is
  read on connect, when a thread starts or closes, and at most a minute apart otherwise; status and name changes are
  applied to the last list as they arrive, so a busy conversation never makes every notification a relist. A
  list a notification arrived during is read again before it is used (a bounded number of times), since the read
  may predate it; a notification for a thread the list does not have yet makes the next scan read the list. A Codex started with settings flags that keep it off the app server, and conversations in the
  ChatGPT app, are not listed, and the codex bundled in that app is never used or counted as an install
  (`CodexInstall.find`). Auto-generated naming threads are not listed. A conversation's title is its name, like a
  tab label, and a rename sets the Codex thread name (`thread/name/set`).
- **Codex delivery starts a turn on an idle conversation and steers a working one** (`CodexDelivery.precheck`,
  `CodexHost.send`). Idle sends `turn/start`; working reads the running turn and sends `turn/steer` with that
  `expectedTurnId`, so a turn that ended in between is refused rather than joined, and is then sent as a new turn
  only when the conversation reads idle; if it still reads busy the message was not taken, so the host answers
  `queued` and the hub holds it to try again, at each state change until the turn ends (two or three app-server
  calls a try). A message Codex did not take is forgotten as KeyScribe's own, so the
  user typing the same words later still reads as typed. Every send carries a `clientUserMessageId` KeyScribe chose, with pasted
  images as `localImage` inputs, and settles as sent once that id appears in the conversation's latest turns,
  re-read for a bounded moment because Codex records it shortly after answering; anything unread is uncertain. A message
  for a conversation waiting on an approval, a question or an unknown state is held in the hub's own queue
  (`AgentHost.queuesInHub`, `AgentOutbox`), under the same rules as a connector's: released when the prompt is
  answered or the turn ends, kept for review when the user typed (Codex's own prompts arrive as `typed`) or stopped
  the turn (the hooks' `Interrupt`, or an interrupted last turn the host reads when the conversation goes idle), and
  reported not sent when the conversation is gone. Every send to such a host, new or released, holds
  its conversation's first place in that queue while it is sent (`AgentOutbox`'s `keeping`), so messages leave one
  at a time in the order spoken, a new dictation waits behind it, and typing or a stopped turn while it is sent still
  marks it. One the host answers `queued` keeps its place and those marks (`AgentOutbox.retry`). Every `queued` the
  Codex host gives is followed by an event: a prompt typed a moment ago is waited out inside the host (it sleeps the
  rest of `CodexDelivery.foreignPromptSettle` and decides again), an approval or a question ends with a status change,
  and a running turn ends with its stop. So the hub does not poll. While the turn runs it waits for that event with no
  deadline; a message marked by typing or a stopped turn goes to review at once; in any other state (an unknown status,
  a system error), `heldLimit` of time spent outside a running turn bounds it, with one timer per conversation and one
  last try at the deadline before it is reported not sent as timed out. One whose conversation was disconnected meanwhile is reported not sent instead. A release the hub stopped before is never sent. A host that answers `queued` (a prompt typed a moment ago) puts
  the message back in that queue. An uncertain send is checked once more after `hostConfirmDelay` through
  `AgentHost.confirm`, which looks for KeyScribe's own message id. KeyScribe never answers
  an approval or a question and never uses Codex's own message queue, and a held message cannot be withdrawn from
  the HUD, as with bb.
- **Codex's plugin reports through hooks, not a connection** (`CodexPlugin`, `CodexHookReport`, sources in
  `Resources/CodexConnector`). Its hooks (prompt submitted, turn stopped, interrupted, permission request, and the
  plan-mode question tool) each run `agents/codex/keyscribe-codex`, which posts the payload to `POST /report` and
  exits 0. The post is synchronous so the hub hears a turn's events in the order Codex ran them (a Stop that overtook
  its prompt would lose the reply), and bounded to half a second so a stalled app barely delays a hook. A post cut off there is lost, not retried: a lost
  prompt leaves that turn's reply unread, and a lost Stop leaves the conversation reading as working until its next
  turn or the next listing that reads it idle. A Stop or Interrupt carries its turn, and so does the interrupted turn the host
  finds on its own, and the hub drops a second end of a turn that already ended, before anything else sees it (the app
  server's turn ids are the session record's `turn_id`s, measured with codex-cli 0.170.0 on 2026-11-19); the end of any other turn is taken, since how Codex numbers a
  turn a message was steered into has not been observed. It sends nothing
  when KeyScribe is not running (config_schema.md, Agent bridge); a payload over the bridge's
  frame limit is cut to the fields KeyScribe reads, with long text shortened. A waiting prompt
  is the approval's tool and command or the question's text. The same executable serves the plugin's
  `tell_me_when_done` tool as an auto-approved MCP server; its one wait is bounded and a timeout promises nothing.
  On the default Codex model when the tool was added, it is called when the user names the app; "tell me out loud"
  alone may make the model reach for another tool. Codex runs the hooks only after the user trusts them with
  `/hooks`, and Settings reads that trust from the app server. Status changes, a cleared approval and the agent's
  last words for a prompt reach the hub as they happen (`AgentHost.watch`). Each conversation is joined to the
  `codex` process whose terminal pane title carries its thread id, through the `thread-id` title item the install
  adds (`CodexPaneTitle`, `TerminalTitleReader`), so Open and in front use the same terminal routes agents use.
  Each terminal or multiplexer is read once per scan, all at once and off the cooperative pool, and the reader returns
  after a budget below the scan deadline with whatever answered; a source that failed, refused or ran past the budget
  leaves its processes unread, never titleless, so the host keeps their last known pane and reads them again on the
  next scan. The budget is an injected wait (`TerminalTitleReader.Wait`) handed a count of the sources that have
  answered, raised only after an answer is queued; production ignores the count, and tests use it to end the budget
  right after a fast source answers, so keep it even though production never reads it. Title commands read standard
  output only. A Ghostty pane the user renamed shows that name instead of
  Codex's title, so it is not joined. The install records how it changed `config.toml` (`CodexTitleItem.Record`,
  kept when Update puts a removed item back), and install and uninstall refuse rather than go on when the file
  cannot be read (only a missing file counts as empty) or has since changed into a shape it cannot safely edit, so the record a retry needs is never deleted. Uninstalling without
  Codex takes the item back the same way before the manual steps delete the folder holding the record
  (`AgentConnector.uninstallWithoutTool`). `hooks/list` with `cwds: [codexHome]` lists a plugin's hooks with their
  trust (measured with codex-cli 0.170.0 on 2026-11-19: `untrusted` right after install, `trusted` once trusted), and a
  running daemon lists a plugin installed after it started at once, with no restart (same version and date), so a check
  that finds none of ours says only that, and offers Update;
  the focused window's title is the fallback for a terminal without a pane title read. A title names a thread only
  when a word of it starts with the thread id (`CodexPaneTitle`), so a session file name or path that contains the id,
  as an editor or browser shows it, is never that thread, while Codex in any terminal still is. Check `CodexHost` for Stop
  before documenting it for Codex.
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
