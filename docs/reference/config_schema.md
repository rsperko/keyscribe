# KeyScribe — Mode & Config TOML Schema

> Companion to `../development/design.md` (§4.3 modes, §4.6 settings, §5 storage, §5.1 versioning).
> Defines the on-disk config: one TOML file per mode plus the shared config files modes
> reference. Every config file carries `schema_version`; older versions are normalized on read
> (`../development/design.md` §5.1).

---

## Directory layout

```
~/Library/Application Support/KeyScribe/
  settings.toml            # general settings + active STT engine
  connections.toml         # named LLM connections (BYOK)
  dictionary.toml          # global dictionary
  replacements.toml        # global replacements
  vocabularies/            # shared vocabularies, one file each (id = filename stem)
  voice_commands.toml      # saved commands for the Voice Commands mode (experimental)
  fragments/               # shared prompt fragments (one file per fragment)
    my-voice.md            #   markdown body + YAML frontmatter
  modes/                   # one file per mode; filename stem = mode id
    _direct.toml             # the Direct system floor (reserved `_` id)
    _voice_commands.toml     # the Voice Commands system mode (experimental; seeded only while its flag is on)
    email.toml
    pig-latin.toml
  history/                 # append-only local history, one JSONL file per day
    2026-06-20.jsonl
    spoken-replies/        #   spoken replies kept for diagnosis, by the day of their entry, then the entry's id
      2026-06-20/<id>/     #     reply.wav, reply report.txt, render 2.wav, render 2 report.txt, …
  spoken-voice/            # the natural voice's own measurements; no text
    baseline.json          #   recent stage timings per second of audio, for "usual" in reports
  usage/                   # replacement use counts (see "Replacement usage")
    replacements.json
  agents/                  # coding agent bridge (experimental; see "Coding agent names")
    token                  #   the access token the Claude Code connector presents
    bridge.sock            #   the local socket the connector talks to
    ready.json             #   present only while KeyScribe is listening on bridge.sock
    claude-connector/      #   one local marketplace per Claude Code setup the connector is installed in
    connectors.json        #   each setup a connector is installed in, and the installation that may connect from it
    names.json             #   names you chose, the names open conversations were given, and disconnected conversations
  lkg/                     # last-known-good mode copies + seed-ledger.toml (design.md §5.1)
  models/                  # downloaded STT weights, one dir per model (design.md §4.1)
    parakeet-tdt-0.6b-v3/
```

- **Mode id = filename stem** (kebab-case). The id is stable; `name` is the display label and
  can change freely.
- **System modes use a reserved `_`-prefixed id** (`_direct.toml` = the Direct floor, shown to users
  as "Plain Dictation", `design.md` §4.3). The kebab-case slugger never emits a leading underscore, so user modes can't collide. Only the built-in ids are treated as system modes; any other `_`-prefixed file is an ordinary mode. The
  file is auto-seeded and re-normalized on load: only its editable fields (trigger keys, insertion,
  trailing, submit, clipboard modifier, live-edits, **and exclude-from-history**) are honored; the
  locked guarantees (no AI rewrite, dictation/cursor only, global vocabulary) are enforced regardless
  of edits. Direct owns Fn by default and records to history per the global setting unless turned off.
- **`_voice_commands.toml`** is a built-in system mode, behind the `voice_commands` experimental flag.
  It is seeded (with no shortcut) only while the flag is on; turning the flag off hides it but leaves the
  file, so a later opt-in keeps the shortcut. Only `trigger_keys[]`, `enabled`, and its own vocabulary
  (`[dictionary]` and `[replacements]`, which include global vocabulary unless `include_global = false`, as
  in every mode) are honored; everything else is forced (`output = "voice_command"`, no rewrite, no spoken
  editing commands, no phrases or constraints). `exclude_from_history` is honored too and defaults to
  `false`, so a voice command is recorded like a dictation: Heard is the transcript and Result is the
  command it ran (a script's program and arguments, quoted the way a shell would), with the reason
  when it failed. It is never the fallback: only its own shortcut starts it. **Its shortcut may not
  be shared with any other enabled mode**, whatever that mode's context: Settings offers to move it, and a
  shared press written by hand stays with the other mode — the Voice Commands binding is dropped, and the
  Modes list and the menu-bar badge mark the mode's shortcut as never firing.
- Config files are human-editable text. **Model weights** are downloaded at runtime (never
  committed) into `models/`, consolidated under the KeyScribe support dir.
- **History records** (`history/<day>.jsonl`, one JSON object per line) are additive: each dictation
  writes `mode`, `heard`, `result`, `outcome`, boundary metadata, and two **optional**
  fields, `mode_choice` (`one_shot` / `trigger_key` / `context_rule` / `spoken_phrase` / `fallback`)
  and `routed_phrase` (present only for `spoken_phrase`). A cloud rewrite also stores the optional
  `received` — the provider's raw reply, verbatim (pre-enforcement, carrying `⟦SN:…⟧` tokens like
  `prompt`, never their originals) — behind History's "Show exactly what was received". Old rows
  lacking optional fields decode as absent — History renders without the corresponding line. Audio
  and the redaction map are never stored.
  Support fields, all optional and absent on older rows: `app_version` and `os_version` (what the
  dictation ran on), `target_app` (bundle id of the app focused when the dictation started — where the text was meant to
  go, even if it was diverted), `delivery_attempted` (the insertion action chosen before actuating, as
  `DictationController.delivery` names it, with the reason when it was diverted, e.g. `clipboard (appChanged)`;
  an `ax` insert can still fall back to paste),
  `stage_ms` (milliseconds per stage, keyed by `DictationRecord.Stage`), `audio_seconds`, `error`, and
  `shortcut_candidates` — every enabled mode bound to the pressed key with its `verdict` (`ModeCandidate.Verdict`) as decided by the shortcut alone, before
  anything was said; a spoken phrase (`mode_choice = "spoken_phrase"`) can still move the dictation to
  another mode afterward. Present only when another mode was on that key or the bound mode could not run
  there. History's detail does not show them; **Copy Report** does.
  Each record also carries an optional `id`, fixed when it is written, which an in-place update (a late
  command result, a clicked choice) keeps; History matches rows and deletes by it. Older rows without one
  are matched by their content.
  A **voice command** writes `outcome = "command"`, `"command_failed"`, or `"command_started"` (an
  action still running, later rewritten to one of the first two). A command that matched more than one
  destination writes `"command_needs_choice"`, its `result` listing the numbered choices; a spoken answer
  is a separate entry whose `result` starts `Selected <name> for “<command>”:`, and a cancelled choice
  writes `"command_cancelled"`. A choice answered by clicking rewrites the question's own entry. Its `heard` is the
  transcript, `transformed` the text after the Voice Commands vocabulary, and `result` what ran: a
  script's command line, quoted the way a shell would, or the description of a switch. A command that
  matched nothing has an empty `result`. A failed command adds the optional `failure_reason` — the
  message the HUD showed, which for a script can include the last line it wrote to standard error.
  A script that reported a result (*Reporting results* under Scripts) adds the optional `reported`, the
  message the HUD showed for it. A choice offered by a script and answered by clicking, whose second run
  asks again, rewrites the question's entry with the new list.
  An app older than this change skips these rows rather than failing to load history.
  A dictation whose rewrite fell back can be rewritten again from History. The entry is updated in place,
  by `id`, to `outcome = "rewritten_later"`: `result` becomes the new text, which was not inserted;
  `connection`, `model`, `prompt`, `received`, `reasoning` and `redaction` describe the new request;
  `context_categories` is empty, because no context is sent; `rewrite_skipped_ms` is removed; and
  `fallback_reason` keeps why the first rewrite fell back. `heard` and `transformed` are kept.
  The optional `summary`, `facts`, and `steps` are written finished by whatever recorded the take, so History shows them
  without interpreting them. `summary` is the strongest outcome in words, shown in place of the outcome label
  (and searched); `facts` are ordered `{label, value}` pairs of context fixed when the entry was written; and
  `steps` are ordered `{at, text}` transitions added when a later result arrives, never removing an earlier one.
  A **Coding agent** take fills them: `summary` says what happened (`Sent to backend`, `Queued for backend`,
  `Opened backend`, or why nothing was sent), and `facts` record the command (Open, choosing a recipient, or a
  message), the spoken address, the conversation chosen with its session id, how it was chosen, the default
  recipient frozen at the start of the take, and for a message that was handed off, `Delivery`: when it was
  handed off and, relative to that, when the agent had it, when it entered the conversation (and whether it
  changed on its way in), whether a receipt was missing and what the check found, why a message that entered
  did not match, a turn followed for its reply, when the receipt arrived, and reconnects while waiting. It
  holds times and fixed wording only and is rewritten as later reports arrive. `result` is the text actually sent,
  empty for an Open. A queued or uncertain message's entry is updated in place, by `id`, when its receipt
  arrives while the app is still running; a receipt after a restart, or after Coding agents is turned off,
  leaves the entry as it was. The update re-reads the entry, so a rewrite that fell back or was skipped
  keeps `outcome = "local_fallback"` with its `fallback_reason` or `rewrite_skipped_ms`, and
  `fallback_reason` is kept even when delivery failed. `outcome` stays
  the coarse `inserted` or `failed` that the rest of History keys on; read `summary` for what reached the
  agent. These fields hold fixed local wording and names, never an agent's reply, a credential, or an
  environment value, and they follow the same History setting and per-mode exclusion as everything else.
  The optional `spoken_reply` is what a Coding agent reply update gave, written once it became audible, or, with the
  voice set to Off — text only, once it was shown: `{at, conversation, text, connection, voice, reason, shown}`, where
  `shown` is `true` only for an update shown without speech (absent otherwise, and then `voice` is absent too), where `text` is the line exactly as heard (a reply, a summary, or how
  a turn ended; a notice is never written), `connection` names the service that wrote the
  line, absent when it was read as written, and `voice` is which voice was speaking when the line became audible:
  `"natural"` (the downloaded voice) or `"macos"` (the macOS voice), absent in entries written before it existed.
  These are identifiers, never display copy (`SpokenAttempt.Reader`); History maps them to its own words.
  `reason`, present only with `"macos"`, is fixed local wording saying why the natural voice did not read it
  ("the natural voice took too long"); it never holds reply text. A reply to a dictated message is added in place, by `id`, to that
  take's entry, and only when the take was kept. A reply asked for from inside the agent is an entry of its own
  under the Coding agent mode's name, with `outcome = "command"`, empty `heard` and `result`, and `summary`
  `Reply from <name>`; it is written only when History is on and the Coding agent mode is not excluded from
  History. A notice on its own is not written.
  Optional fields come later, written in place by `id`: `check` (`{heard, error_rate, checker}`), what on-device
  speech recognition heard the last time Check Audio listened to the natural voice's generated audio for that reply,
  its error rate against the text read, and the speech engine that checked it (see "Spoken reply checks"); `kept: true` once the reply's evidence was written under
  `history/spoken-replies/`; and `rendering` (`{voice, sentences}`), the natural voice's id and the sentences it
  read one at a time, written when the reply is kept, so Render Again can repeat the same inputs after the generated
  audio is gone. A reply never kept falls back to the current voice reading it in one piece. Evidence is written only while the entry is still on disk, under the same
  lock as delete and retention. Deleting the entry deletes its folder there first; if the folder cannot be removed,
  the delete fails and the entry stays, so it can be retried. Retention drops those folders by day with the day files,
  folders first; a day whose folder cannot be removed keeps its day file, so its entries stay in History and the next
  sweep tries again.

### Spoken reply checks

A check runs only when asked: Check Audio in History, for the generated audio still held for the reply or the
`reply.wav` kept for it, or Check beside a saved render. Nothing is checked in the background, and Render Again only
renders. The active speech-to-text engine transcribes the whole audio in one pass, as the threshold below was
measured; held audio is written to a temporary file for that pass and deleted after it. A check asked for while a
dictation is recording or transcribing is refused, not queued. A dictation committed while a check holds the transcription gate waits until the engine call really returns (the
gate's `isBusy`, which outlasts a deadline or a cancellation the engine ignores), with no limit of its own: engines
are serialized, so nothing could transcribe it sooner. The HUD says it is waiting for Check Audio, and after a while
that the check is taking longer than expected and that quitting discards the recording; the recording is kept until it is transcribed or the user discards it, and
transcription starts on its own once the check ends. Only a
check that entered the gate is waited for, and only until its own work ends; a check refused by a busy gate leaves
the next dictation to the usual busy handling.

The result is compared with the words read (`SpokenReplyCheck`): the error rate is the character edit distance over
letters only, with apostrophes left out and numerals spelled out as words on both sides, since speech recognition
writes "three thousand" as "3,000" and "backend" as "back-end". Text with no letters or numerals to compare is not
checked. A rate at or above `SpokenReplyCheck.mismatchRate` marks the audio as not matching its text. As measured on
2026-11-12 with Parakeet Ultra (`parakeet-ultra`) over 60 natural-voice renders of 30 typical reply lines, clean
renders scored at most 0.04 (by words, before this normalization, up to 0.40), a reply heard only halfway at least
0.40, and an unrelated sentence at least 0.75. History shows "The generated audio may not match the reply." only for
a checker in `SpokenReplyCheck.calibratedCheckers`, the engines the threshold was measured on; other checkers'
results show in Playback details. A check of the reply is written to the entry's `check` and, when the reply was
kept, replaces the check line in `reply report.txt`; a check of a render replaces the check line in that render's
report and leaves the entry alone. A check keeps nothing by itself.

Every natural-voice render records its conditions in its report (`RenderConditions`: app and voice uptime, renders
since the voice loaded, other work in the app that overlapped the render, thermal state, memory pressure, the app's
memory, load average, and each stage's time against `baseline.json`). `baseline.json` holds no text. The voice
writes it at most once a minute and when it unloads; it keeps the last `SynthesisBaseline.window` timings per stage in milliseconds per second of audio, and a stage has a usual time
only after `SynthesisBaseline.minimumRenders` renders.

### Model storage

All KeyScribe data — including STT weights — lives under the one support dir. KeyScribe **points each
engine SDK at `models/<model-id>/`** where the SDK exposes a configurable download directory; where
it does not, KeyScribe manages the SDK's own location through that SDK's API and the result is the
same single disk-usage / delete story for Speech Models settings. **Apple's speech
models are system-managed** when available and have no entry here.

- **Application Support, not Caches** — weights must not be purged mid-session; they are
  re-downloadable, so deletion is always safe and the dir is marked excluded-from-backup so
  Time Machine does not store re-downloadable data.
- The `models/` dir is **not** versioned config and carries no `schema_version`.

---


## Replacement usage

`usage/replacements.json` records how often each configured replacement changed a dictation that
reached its destination. It is app-written state, not config: it carries a JSON `schemaVersion`, it is
never hand-edited, and a write to it does not reload configuration.

- One entry per rule, keyed by scope (`global` or `mode:<id>`), kind (`l` literal, `r` regex), and the
  heard text — lowercased for a literal, verbatim for a regex. The replacement output is not part of
  the key, so rewording **Use instead** keeps a rule's count; changing the heard text or the regex flag
  starts a new one. Renaming a mode carries its rules' entries to the new id.
- The file stores `trackingSince`, the day counting began. Each entry stores `count` (dictations, not
  matches — a rule matching twice in one dictation counts once), `lastUsed`, and `since`: the day the
  rule first appeared, or absent for a rule that already existed when counting began, whose real add
  date is unknown. Dates are local days (`yyyy-MM-dd`), never timestamps, and no dictation text is
  stored.
- A rule counts only when the dictation was inserted or copied; a cancelled, empty, or failed one
  never counts. For a voice command, a rule counts only when the command ran (it finished or started);
  an unrecognized, refused, or failed command never counts, and neither does one that asks which
  destination to use. The spoken answer to that question counts its own rules when the chosen command runs. A whole-utterance replacement counts only the rule that owns the utterance. A count
  lands only on a rule that is still configured when the dictation finishes: one removed mid-dictation
  is not brought back, and one whose mode was renamed mid-dictation counts under the new id.
- A failed write is logged and retried on the next change; the in-memory counts are never discarded.
- Counting is independent of the History setting. Entries for rules that are no longer configured are
  dropped whenever configuration loads cleanly; a config file that fails to load leaves the counts
  untouched. A usage file that cannot be read (corrupt, or written by a newer version) is moved aside
  to `replacements.json.unreadable`, logged, and counting starts fresh — it is never silently
  overwritten. Only the most recent unreadable copy is kept; if it cannot be moved, counts are kept in
  memory only until the next launch rather than written over it.

## Coding agent bridge

Every agent connector talks to KeyScribe over HTTP on `agents/bridge.sock`, presenting `agents/token`
as a bearer token; the Claude Code connector is a plugin, the Pi connector an extension, and both speak the
same protocol. It sends events with `POST /event` and long-polls for commands with `POST /poll`; a
`409` answer means KeyScribe no longer knows that connector, which says hello again. The message types are
`AgentEvent` and `AgentCommand` in `AgentBridge.swift`, versioned by `AgentBridgeCodec.protocolVersion`;
a hello on any other protocol is refused with `426` and is never registered or sent commands.

- **A connector is installed into a setup, and only enrolled setups connect.** A setup is the folder an
  agent loads its configuration from: Pi's agent folder (`~/.pi/agent` unless a conversation's
  `PI_CODING_AGENT_DIR` names another) and Claude Code's config folder (`~/.claude` unless its
  `CLAUDE_CONFIG_DIR` names another). KeyScribe finds the setups conversations actually use from their own
  processes, never from its own environment, and lists the default too; finding a setup never installs into
  it. `agents/connectors.json` (`ConnectorSetups`, with `schema_version`) lists each setup a connector was
  installed in, as `agent`, `folder` (with symlinks resolved), `installation` and `removing`. Installing
  enrolls the setup with a new `installation` id before anything is written, and an update keeps the id.
  Every hello carries the id its connector was loaded with, and KeyScribe refuses with `403` any id that is
  not enrolled, or whose setup is being removed. A file that cannot be read admits no connector and refuses
  every install and uninstall until it can; Settings says so and **Try Again** reads it again. One that
  later becomes unreadable keeps the setups already loaded.
- **Removing one setup leaves the others connected.** Removal marks the setup `removing` first, then sends
  `retire` to that installation's connectors waiting for commands without waiting for an answer, and
  withdraws their outstanding commands; connectors of other setups and other agents keep working. Only once
  the agent no longer lists the connector is the entry dropped; an entry still `removing` means an uninstall
  did not finish, and finishing it never readmits the old id. A connector told to retire, one whose hello is
  refused with `403`, or one whose settings now name a different installation, stops for good until the
  agent loads it fresh. The install writes the id into the connector's code as well: Claude Code's
  `/reload-plugins` loads only code that changed, so code identical to a retired copy would leave that copy
  in place.
- **Claude Code commands run against the chosen setup.** Each setup gets its own local marketplace under
  `claude-connector/`, registered and installed at user scope with `claude plugin` commands run with that
  setup's `CLAUDE_CONFIG_DIR` (and without it for the default setup), so no other setup's plugins change.
  Uninstalling runs each removal step even when an earlier one fails, and deletes that setup's marketplace
  folder only once `claude plugin list --json` and `claude plugin marketplace list --json` no longer show
  the connector.
- **The Pi connector is a folder in the setup's `extensions/`.** It is installed by writing that folder and
  uninstalled by deleting it; Pi loads whatever is there when it starts or on `/reload`, so no Pi command
  is run. The folder's `keyscribe.json` carries the connection settings, the installation id, the connector
  version, the environment keys the terminal routes read, and their focus commands (see Hello). An extension turned off in the setup's
  `settings.json` (an `extensions` entry `-path` or a matching `!pattern`, unless `+path` brings it back) is
  reported as turned off, and an update never turns it back on.
- **Updates keep setups as they are.** When KeyScribe starts, it updates the connector in each enrolled setup
  whose installed copy differs from the bundled one, and never in a setup that is not enrolled or whose
  connector the agent has turned off. Open conversations keep the connector they loaded, which keeps working,
  until they reload; Settings notes a conversation whose hello reports an older `version`.

- **The connector connects only when KeyScribe is listening.** KeyScribe writes `agents/ready.json`
  (`launch`, a new random id each time the bridge starts, and `protocol`) after its socket is listening,
  and removes it when it quits, the feature is turned off, or the bridge fails to start. While the file
  is missing the connector only rereads it, about every 10 seconds per session, and makes no connection
  attempt. A launch whose socket refuses the connection is not tried again until `launch` changes. A
  bridge that stops answering is greeted once at once, then after growing waits (about 30, 60, 120,
  then 300 seconds, with jitter) while it stays unresponsive; a new `launch` ends the wait. A rejected
  hello, a `protocol` the connector does not speak, or missing connector settings make the connector go
  quiet until the next session or a plugin reload. It clears only a status line or button it showed
  itself.
- **Hello** names the agent, the connector instance, the session id, the agent's process id, the connector
  `version`, and the features the connector offers. A connector whose agent keeps no session registry (Pi) also sends the session's
  working directory (`cwd`), and its hello is how KeyScribe learns the session exists: the session is listed
  while its process runs, and a hello from the same process for another session id replaces the earlier one
  (`/new`, `/resume`, `/fork`). The start time recorded for such a session is its process's start time; a
  session whose start cannot be read has none, so its name is not remembered across a restart, until a later
  hello reads it. A hello for a known session from another process takes that process's start time.
  KeyScribe uses only what was announced: `label` for the status-line label naming the conversation, and
  `focus` for selecting the connector's own terminal surface during Open when the terminal cannot be
  told which surface from outside (cmux, when no process shows the agent's surface id). A connector that lacks
  `focus` is reported as outdated, with the steps to update it. With `focusDefinitions`, a `focus` command
  names one of the focus commands the routes declare (`FocusDefinition`, written into each connector's
  `keyscribe.json`): the connector runs it only if it is listed there, every variable it names is set in the
  agent's own environment, no value starts with `-`, and the request has not expired and the session has not
  changed. Each value replaces a whole argument, the command starts with an absolute program path (`/usr/bin/env`
  still finds the program it names on the agent's `PATH`), no shell runs it, and it runs under a short
  deadline. A connector without `focusDefinitions`, or one still running on a configuration from before the
  named command existed (it answers `unknownFocus`), is reported as outdated: Open brings the terminal
  forward and gives the steps to update and reload. A hello may
  carry the conversation's title, and an `environment` map with terminal facts only the agent's own process
  can read (its Zellij pane); the connector reads only the keys its terminal routes use
  (`ResolvedSurfaces.environmentKeys`), and KeyScribe keeps only those. The Claude Code connector reads each
  variable by name, as Claude Code requires, so installing writes one read per key into its script; a key
  that is not a plain variable name keeps the routes from resolving. A change to the keys or focus commands
  changes the connector version, so Settings offers the update.
- **Every command names the session it expects**, and the connector refuses one whose session has changed.
- **A disconnected conversation goes quiet.** KeyScribe answers the hello of a conversation listed in
  `names.json`'s `excluded` with `{"ok":true,"quiet":true}` and passes on only who it is (agent, session,
  process, folder), never its title, prompt count, open dialog or terminal facts. A quiet connector keeps
  one long poll open and observes nothing; later events from that conversation are answered and dropped.
  Disconnecting a connected conversation sends it `quiet`; reconnecting sends `admit`, and the connector says
  a full hello again without a reload. Until `names.json` can be read, every conversation is treated as
  disconnected.
- **Each hello opens a new connection.** It carries a fresh `connection` id, and every later poll, event
  and reply carries that id and the connector's `instance`. KeyScribe answers `409` to anything from a
  connection that a newer hello replaced: it is not passed on, and it does not count as that connector
  still being there. A command the old connection collected is reported as uncertain, never sent again
  over the new one, even when its acknowledgment arrives late. KeyScribe sends an unacknowledged command
  again only over the connection that collected it.
- **The connector runs each command once per connection.** It remembers, in memory, the ids it has
  accepted on the current connection, and only acknowledges a repeat. Nothing is written to Claude Code's
  plugin storage. When that memory is full, the connector drops the connection before accepting more and
  says hello again; the forgotten ids go with the connection they belonged to.
- **The connector never makes Claude Code wait.** Its hooks only record what happened and hand the
  event to one background sender, which delivers events and replies in order. Nothing a hook sees is
  sent before that session's hello succeeds, and nothing missed while disconnected is replayed later. An
  event that KeyScribe does not answer within its deadline, a poll that outlives its hold, a failed
  delivery, or a full outgoing queue counts as a lost connection: the connector stops acting on what it
  had, clears what it showed, and says hello again once its earlier request has finished. It never opens a
  second request around one that has not finished. A deadline that ran out only because the agent's own
  process stalled (its timer fired a second or more late) is restarted instead, a bounded number of times, so
  an agent busy starting a turn is never mistaken for an app that stopped answering.
- **A receipt outlives its connection.** A submission the agent already has is not something to act on
  again, so a lost connection never drops it: its `submitted` receipt (with `handedAt` and `seenAt`, epoch
  milliseconds) is kept until KeyScribe answers it and is sent again on the next connection, for a bounded
  time and number. Only leaving the session or retiring the connector forgets it.
- **KeyScribe checks before it doubts.** When a receipt is late, or a connection is lost after a submit was
  collected, KeyScribe sends a connector that announces `check` a `check` command naming the request, with a
  short deadline. The connector answers `checked` with where that submission is: `holding` (not yet handed to
  the agent), `handed` (the agent has it, but it has not entered the conversation; `miss: "other"` when another
  message entered meanwhile), `seen` (with its turn), `refused` (with the reason), or `unknown`. `seen` settles
  the take as sent; `refused` settles it exactly as the same refusal sent directly would (a busy agent queues
  it again, a draft keeps it for review). The answer echoes the check's `id`, so an answer for an earlier
  attempt never settles a message sent again. Anything else, or no answer, reports it as uncertain, and a
  connector whose session is retired or gone is not asked. A take left uncertain with no answer from its
  connector still follows a turn: the one that started while it awaited its receipt, or else the next one in
  that conversation, unless the user typed in that conversation at any point since the hand-off or a turn
  that started during the hand-off has already ended. A connector that answered `handed`, `holding` or
  `unknown`, even after the take was left uncertain, vouches that no turn so far is the take's: the hub stops
  following on the take's behalf (keeping a reply the user asked to hear) and only a late receipt counts. A
  late refusal, direct or found by a check, stops following the same way.
- **Each attempt has its own request id.** A message sent again after a `working` refusal goes out under a new
  `id` (the first id with a `~` and the attempt), because a connector acknowledges an id it has already handled
  without acting on it. Receipts, refusals and checks for an earlier attempt are ignored; History keeps the
  first id.
- **A hello says whether anything may have been missed.** It reports whether the session is known to be
  idle and whether it resumes after a gap (a lost connection, a resumed session, or a reloaded connector).
  When it resumes after a gap, KeyScribe reconciles before it accepts the hello: takes it was holding for
  that conversation, and commands the connector had not collected, are kept for review; a command the
  connector may already have carried out stays uncertain. A connector that does not announce
  `readiness` is always treated as resuming after a gap, and as busy until the agent's own session
  record says it is idle.
- **A submit carries a deadline** (`expiresAt`, in epoch milliseconds, like a focus): the end of KeyScribe's
  receipt timeout. The connector checks it immediately before it submits, after any wait of its own, and
  refuses a late submit as `expired`, so a take KeyScribe has reported as uncertain never starts afterwards.
  The deadline is required: a submit without one is refused as `expired` too, so a connector never
  submits text whose lifetime KeyScribe did not bound. A queued submit whose deadline passes before the
  connector collects it is never handed over and is reported as not sent (`expired`); one the connector
  had already collected stays uncertain.
- **A submit is refused as `working`** when a turn is already running in that session; KeyScribe holds
  the take and sends it when the turn finishes.
- **A submit is refused as `draft`** when the agent's prompt box holds text the user has not sent; the
  connector leaves that text in place and KeyScribe keeps the take for review. The connector checks the
  prompt count, a running turn, and the session again after reading the box, right before it submits.
- **A submit is refused as `dialog`** when the agent is showing a dialog of its own (Pi reports these around
  every extension prompt); KeyScribe keeps the take for review.
- **The Pi connector waits for the keyboard.** A key pressed in that terminal within the last three seconds
  holds the submit until three seconds have passed since the last key, for at most six seconds, rechecking
  the refusals above after every wait. It then hands the text to Pi as a follow-up message with an invisible
  mark of its own appended: a short run of zero-width characters encoding a random value drawn when the
  connector loaded and a count of its submissions, so no two submissions share a mark, within one connector
  instance or across reloads, and the clock plays no part (Pi gives an extension no other identity for a
  message it submits). The connector reports `submitted` only when a user message carrying
  that submission's mark enters the conversation, whatever input came before it, so the same words submitted
  again or by another extension, a prompt the user typed, or a message delayed across a reload can never
  confirm it. A marked message whose text changed on its way in (another extension's input hook, or Pi noting
  a resized image) still confirms it, reported as `altered`; a message another extension consumed never does. Until a receipt arrives the outcome is unknown: the connector keeps waiting
  (another extension's input hook may hold the message for a while), KeyScribe's own receipt timeout checks, then reports
  the take as uncertain and, after a bounded wait, lets later dictation to that conversation go ahead and
  forgets the request; a receipt that arrives within that wait still settles it as sent, and one after it
  leaves the take uncertain. A submission stops holding further dictation after
  three seconds, and only the most recent such submissions are still matched; one dropped from that list
  stays uncertain. Text starting with `/` or `!` reaches Pi as plain text.
- **A submit names its own turn.** The Claude connector reports the turn whose prompt is the text it
  submitted, and no turn when it cannot tell (another mod may rewrite the prompt), so a turn the user started
  meanwhile is never taken for the dictation's. A submit that names no turn is still confirmed as sent, but
  no turn's reply is spoken for it. The Pi connector treats Pi's automatic retries and continuations as one turn, and closes a run
  Pi never reported settled once Pi has been idle across two checks a couple of seconds apart, reporting it
  with reason `unknown` and no answer.
- **A completed turn carries the agent's final reply** in `answer`: the last assistant text of the turn, without
  thinking or tool calls, bounded by each connector to its opening and its ending. KeyScribe keeps it in
  memory only, for the spoken result of a turn its own dictation started or that the user asked to hear, and never
  writes it to History or logs. A turn that was stopped or failed carries no answer.
- **A connector can ask for a turn's reply to be read aloud** with `notify` (`session`, `turn`, `on`): `turn` names
  the running turn, or is empty for the next one, and `on: false` cancels. The bridge answers `spoken`, whether spoken
  replies are on, or `quiet` for a disconnected conversation. A connector that sends it says so with the `notify`
  feature on its hello, and that hello also names the turn it is running in `turn`.
- **The session id comes from Claude Code's session lifecycle.** When a session ends or is replaced
  (`/clear`, `/resume`, `/branch`), queued events for the old one are dropped and its commands refused, and
  the connector says hello for the new id before sending anything else.
- **Typed events** report a prompt the user submitted (in the agent's own input, through Remote Control, or from Slack)
  and any prompt Claude Code cannot attribute to a program; the Pi connector counts prompts typed in Pi's own
  editor. Prompts from plugins (the connector's own
  submissions included), background tasks, and scheduled triggers are not counted.
  One holds a queued take for review and makes that conversation the current recipient. Hello and each typed event
  carry the count of prompts the user has submitted in that session; each submit carries the count
  KeyScribe last heard, and the connector refuses it as `typedSince` when the count has moved since, so a
  prompt the user typed is never overtaken by dictation decided before KeyScribe heard about it. That
  refusal holds the take for review like a typed event does. Claude Code runs
  slash commands and `!` shell commands without the hook the connector listens on, so they send no typed
  event.
- **Title events** carry the custom title the user gave the conversation, as reported in Claude Code's hook
  payload, or the session name set in Pi, which reports every change including a cleared name. The connector sends one only when the payload includes the title field, and sends an empty
  title (name cleared) only after it has reported a non-empty one, so a Claude Code build that omits the
  field never erases a name found elsewhere.
- **Turn events** report a turn starting and ending, never the agent's answer. Pi's turn ends only when
  Pi settles, after retries and queued follow-ups, and a run ended with Escape is reported as aborted.
- **The status-line label is cleared by the connector** when KeyScribe stops answering, so a label never
  outlives the app.

## Coding agent names

`agents/names.json` holds the names chosen with **Rename…** on the Coding agent page, keyed by the
agent's session id (`{"schema_version": 1, "names": {"<session id>": "backend"}}`), and in `excluded` the
session ids of conversations you disconnected (`"excluded": ["pi:<session id>"]`). A disconnected conversation
stays disconnected when it resumes; a new or forked conversation has a new id, so it connects normally. Without an override,
the conversation uses its explicit native name, normalized like a name chosen in KeyScribe. Only an
unnamed conversation gets a name generated from its folder. Like `usage/`, it is app-written
state, and a write to it does not reload configuration.

- Chosen names are restored before any generated name is handed out, so a name keeps meaning the same
  conversation across restarts, and a chosen name stays reserved while its conversation is closed.
- `remembered` holds the name each running conversation was given without a chosen name, with the
  agent's pid and the start time recorded for that process (the one Claude Code recorded, or for Pi the
  process's own start time)
  (`"remembered": {"<session id>": {"name": "keyscribe blue", "pid": 4821, "started_at": 1793454517559, "native": null}}`).
  After a KeyScribe restart a conversation gets its remembered name back only when the same process is
  still running, so names do not move between open sessions. A session missing from a scan keeps its
  entry, and its name stays reserved, while that process runs: a missing registry file is not a closed
  session. Once the process has exited, or its pid belongs to a process started at another time, the
  name is free for the next new session and the entry is dropped. If the native name changed while
  KeyScribe was closed, the new native name is used instead.
- These names take effect even when they cannot be saved; Conversations then says so, and every later
  refresh tries again. A rename, by contrast, is never applied unsaved.
- For Claude Code, explicit names come from the connector's custom title, registry names whose
  `nameSource` is `user`, or a `custom-title` transcript record. Automatically generated `ai-title`
  records and registry names marked `auto` or `derived` are descriptive text, never addresses.
  An omitted name in a connector hello leaves registry/transcript discovery available; an explicit
  name-cleared event overrides stale metadata. A subsequent registry rename can supersede that report.
- Before the agent's own name come what herdr shows on the conversation's pane (the `title` a hook reports
  through `pane report-metadata`, else the pane's `label`) and then the name the user gave the agent in
  herdr (`herdr agent list`'s `name`). Names that normalize alike, including the same name on two herdr
  servers, are qualified by their agents and the bare name asks. Herdr is read for the agent names on every
  place read; a read that cannot list them leaves every place unchecked, so the last names stay.
- The pane label and the herdr agent name still reach a conversation whose shown name came from a higher
  source; a pane title, and the agent's own name when a herdr name outranks it, do so only when said in full
  after “tell”, “ask” or “open” (part of one is message text); a tab or workspace label of one conversation
  holds the take and names the conversation. These other names are read with the
  places and never saved.
- Other places give names by the same levels, innermost first, read from each tool's own listing: tmux
  window names with `automatic-rename` and `allow-rename` off and non-numeric session names while `status`
  is on; Zellij tab names other than `Tab #N` (pane titles follow the program's title and are not read); Ghostty terminal and tab `name override` (tabs only in windows whose tab and terminal counts
  match); iTerm's `tab.titleOverride`. Terminal-app reads use Automation only where it is already allowed.
  Program-written titles (OSC 0/2, tmux `pane_title`, Zellij pane titles, Ghostty `name`, Terminal custom
  titles) are never read. Each tool is asked once per read for all conversations. A read that fails keeps
  a conversation's names when it had a place and reports no place when it never had one.
- After the agent's own name comes the label the user gave the conversation's place: its tab's label when
  it is not the tab's number, else its workspace's label. A tab or
  workspace label covering several conversations is followed by each conversation's agent, and a bare
  label then asks which one. Place labels are not saved; they are read from herdr while the app runs.
- A native rename updates an unaliased conversation; a KeyScribe override keeps winning until changed
  in KeyScribe or removed with Use Default Name. Duplicate names gain a distinguishing word without taking an existing conversation's
  handle. A native name that is empty after normalization or uses reserved `session <number>` syntax
  falls back to the folder. Identity, pending delivery and a recording's frozen name table remain bound
  to the original session id.
- A rename is saved before it takes effect; if the file cannot be written, the rename is refused and
  every name stays as it was.
- An absent file means no chosen names. A file that cannot be read, is malformed, or was written by a
  newer version is **left as it is**, never moved aside or overwritten: until it loads, a take starting
  with "tell" reaches a conversation only through a row number, never the current recipient (unaddressed
  takes, including one that starts with a name but no "tell" and one that starts with "ask" and no row number, still go to
  the current recipient), Rename is unavailable, and the
  Coding agent page says why, with **Try Again**. This differs from `usage/` on purpose — starting fresh
  there costs counts, while starting fresh here could hand a familiar name to a different conversation.
- Session ids and names are kept whether or not History is on, until the file is deleted. No message
  text is stored there.

## Mode file — annotated example

`modes/email.toml`

> **TOML ordering (load-bearing).** Every root-level scalar key (`name`, `enabled`,
> `trigger_phrases`, `source`, `output`, `insertion`, `exclude_from_history`) must appear
> **before** the first table or array-of-tables header (`[[trigger_keys]]`, `[constraints]`,
> `[commands]`, …). A root key written after a `[[table]]` header silently parses as a member of
> that table, not the mode. So: all the mode's scalars first, then the table sections.

```toml
schema_version = 2
name = "Email"
enabled = true

# source: "dictation" (default) or "selection" (edit-in-place: capture the current selection as
# content, dictation becomes the instruction). output: "cursor" | "replace_selection" | "speak".
source = "dictation"
output = "cursor"

# Trigger phrases. One or more spoken phrases matched at the END of the transcript
# (raw-suffix routing). Matching is case-insensitive, tolerates trailing punctuation/whitespace
# that STT appends, and honors word boundaries — so a bare phrase just works:
trigger_phrases = ['as an email']
# A phrase is itself a regex, so power users can write one for alternation/optional words:
trigger_phrases = ['as (a |an )?(draft|note)']
# Do NOT add (?i), \b, or a trailing $ — the matcher already supplies case-insensitivity, word
# boundaries, and end-anchoring AFTER trimming the punctuation/spaces STT appends (so a literal $
# would match anyway, but it is redundant). Use (?-i) only to force case-sensitivity. Optional.

insertion = "paste"          # "paste" (default) | "insert" | "type"
trailing = "space"           # "none" | "space" (new-mode default) | "newline" — appended INSIDE the atomic insert
submit = "none"              # "none" (default) | "return" | "shift_return" | "cmd_return" — keystroke AFTER a verified insert
paste_key = "command+v"      # chord posted to paste an insert (same grammar as trigger_keys[].key); e.g. "control+shift+v" for a Linux guest terminal
copy_key = "command+c"       # chord posted to capture a selection (source = "selection" modes)
# clipboard_sync = true      # leave the scratch clipboard readable + unrestored for a guest/remote clipboard agent.
                             # Defaults to true when paste_key has no ⌘; set it explicitly for a target that
                             # translates ⌘V remotely (RDP) but still syncs the clipboard across the wire.
paste_settle_ms = 0             # 0 (default) | ms to wait after writing the clipboard, before the paste keystroke; for a synced guest/remote clipboard whose host→guest propagation lags
trim_trailing_punctuation = false  # strip a final . ! ? (and trailing whitespace) from the result, BEFORE `trailing` is appended
exclude_from_history = false

# ── When it runs ─────────────────────────────────────────────────────────────
# Trigger keys. Each has a press style: "hold-or-tap" | "hold-only" | "tap-to-toggle" | "double-tap" |
# "start" | "stop".
# "hold-or-tap" = push-to-talk while held, OR fires on a quick tap.
# "double-tap" = two quick taps start, one more press stops; single modifier keys only (e.g. "fn",
# "right_command", "command"). On any other key it acts as the default style.
# "start" starts a dictation; another press while busy is ignored. "stop" finishes the current
# recording, regardless of which mode started it. Releasing either key does nothing. TOML-only for now.
# Use distinct keys for the two actions; their scope and idle behavior are described below.
[[trigger_keys]]
key = "right_option"        # canonical key descriptor; also e.g. "fn", "left_command+left_control",
                            # "control+`" (see "Key descriptor format" below)
press_style = "hold-or-tap"
tap_threshold_ms = 250      # release under this = a tap (latches on); over = push-to-talk hold

# Each entry has its own press style. Settings edits only the first entry's shortcut.
# [[trigger_keys]]
# key = "mouse4"
# press_style = "hold-only"
#
# Two pedals: one starts, the other stops.
# [[trigger_keys]]
# key = "mouse4"
# press_style = "start"
# [[trigger_keys]]
# key = "mouse5"
# press_style = "stop"

# Context eligibility. Empty = eligible everywhere. A constraint ANDs its fields; any of
# bundle_id (exact), bundle_prefix (case-insensitive bundle-id prefix), url_pattern (regex, when
# detectable), window_title (regex). Also constrains which phrases can route here. Specificity ranks
# url_pattern > window_title > bundle_id > bundle_prefix (design.md §4.3).
[[constraints]]
bundle_id = "com.apple.mail"
# bundle_prefix = "com.jetbrains."        # optional; matches all bundle ids under the prefix
# url_pattern = 'mail\.google\.com/.*'    # optional; best-effort
# Pair url_pattern with bundle_id in the SAME block to also release the trigger key outside that
# browser: a url-only rule cannot be disproved without probing, so its key stays claimed everywhere
# and an out-of-scope start press starts and cancels. With the bundle present the press resolves before the
# mic opens and is a silent no-op (design.md §4.3).
# window_title = '(?i)pull request'       # optional; regex against the focused window title
# The editor's friendly "Website…" field stores a generated host-anchored url_pattern
# (host = the entered domain OR a subdomain of it), e.g. github.com →
# (?i)^[a-z][a-z0-9+.-]*://([^/?#]*\.)?github\.com([/:?#]|$). The on-disk shape is unchanged (still a
# url_pattern regex); a hand-written pattern keeps today's unanchored substring semantics.

# ── Pipeline commands (spoken-command / pipeline features, opt-in per mode) ──
[commands]
live_edits = true           # spoken commands: "insert new line" / "insert new paragraph" /
                            #   "insert tab character" / "scratch that" / "insert clipboard contents"
                            #   (pastes the clipboard, protected like verbatim) /
                            #   "begin verbatim".."end verbatim" (verbatim is a live edit)
privacy    = false          # best-effort redaction (the mode's privacy toggle).
                            #   When true, context is forced off (see [ai_rewrite].context).
numbers    = false          # inverse text normalization: "twenty five" -> "25"
                            #   (leaves year idioms like "twenty twenty six" as words)
# (Dictionary recovery is not a mode command and has no toggle: it runs automatically whenever the
#  mode's merged dictionary is non-empty. The one mechanism control is the per-engine recognition-bias
#  disable under settings.toml [stt]; see recognition_bias_disabled_engines.)

# ── Vocabulary (mode-local; may exclude the global sets) ─────────────────────
[dictionary]
include_global = true
words = ["KeyScribe", "Parakeet"]

[replacements]
include_global = true
[[replacements.rules]]
heard = "at gmail dot com"
replace = "@gmail.com"
regex = false
[[replacements.rules]]
heard = '(\d+) dollars'
replace = '$$$1'
regex = true                # regex allows capture-group substitutions

# ── AI rewrite (optional; omit the whole [ai_rewrite] table to disable) ──────
[ai_rewrite]
connection = "gemini-flash"     # references a [[connection]] in connections.toml by id
prompt = "Rewrite the dictation as a clear, professional email. Keep my meaning."
fragments = ["my-voice"]        # shared prompt fragments, appended in order
# Context opt-in (what gets sent to the LLM):
context = { app = true, preceding_text = false }
                                                     # selection is sent when source = "selection".
                                                     #   preceding_text = bounded text before the caret
                                                     #   (native-only, best-effort via AX).
                                                     #   Forced to all-false when commands.privacy = true.
```

### Mode field reference

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | Required. Current: `2`. Older versions are normalized on read; v1→v2 migrates the retired `clipboard_modifier` key (`"control"` → `paste_key = "control+v"` + `copy_key = "control+c"`; `"command"` was the default and just drops). |
| `name` | string | Display label. |
| `enabled` | bool | Disabled modes are ignored by the resolver. |
| `trigger_keys[]` | table[] | `key` (canonical descriptor) + `press_style` + `tap_threshold_ms` (default 250). Zero or more; every entry starts the mode except a `stop` entry, which only stops the recording dictation. `double-tap` applies only to a single modifier key; both starting taps must be the same physical key (a sideless `command` accepts either side, but not left then right), and a key, click, scroll, or other modifier between or during taps cancels that tap without stopping a recording in progress. Settings edits the **first** entry and preserves the rest; the `start` and `stop` styles are TOML-only. Further entries are TOML-only and appear in the mode editor as a read-only "Also starts with" / "Stops with" note; a later entry that is the same press as an earlier one (`command` after `right_command`, or the same key twice) is ignored at runtime, the note says so, and it is left out wherever the mode's shortcuts are listed. There is no separate global hotkey — whichever mode owns Fn (the Direct floor by default) is "the global hotkey". |
| `trigger_phrases` | string[] | Spoken phrases matched at the transcript end post-STT — case-insensitive, word-boundary-honored, trailing punctuation/space tolerated. Each is a regex, so power users can write one (`(?-i)` opts back into case-sensitivity). Zero or more. |
| `constraints[]` | table[] | Any of `bundle_id`, `bundle_prefix`, `url_pattern`, `window_title` (ANDed). Empty ⇒ eligible everywhere. |
| `source` | enum | `dictation` \| `selection`. |
| `output` | enum | `cursor` \| `replace_selection` \| `speak` \| `voice_command` \| `agent`. `speak` answers the spoken request about the selected text and reads the answer aloud; the selection is not changed. It needs `source = "selection"` (a file that pairs it with `dictation` fails to load), runs only while the `ask_about_selection` experimental flag is on, and ignores the insertion, `trailing`, `submit`, and context settings: only the selection and the spoken request are sent. `voice_command` is the Voice Commands system mode's output: the take is run as a command (`voice_commands.toml`) and nothing is inserted. `agent` is the Coding agent system mode's output: the take goes to a coding agent conversation ("Coding agent bridge" above). Any other mode file that sets either fails to load. |
| `[agent]` | table | Read only with `output = "agent"`. `target` picks the conversation a take goes to when it does not start with one's name: `current` (default) is the conversation the front terminal shows when the take starts, if that can be confirmed in the window that had focus, without asking for access, shortly after release at the latest, and otherwise the current recipient; `ask` holds the take until one is named, and any other text is the name of a fixed conversation (the take is held if no live conversation has that name). An older `focused` is read as `current`. |
| `commands.live_edits` | bool | Opt-in to the spoken-command list (insert new line, insert new paragraph, insert tab character, scratch that, **never mind** / **start over** to discard the whole take, **insert clipboard contents**, **begin/end verbatim**). |
| `commands.privacy` | bool | Opt-in to best-effort redaction. When true, **context is forced off** — `ai_rewrite.context` is locked to all-false so only the redacted transcript leaves. |
| `commands.numbers` | bool | Opt-in to inverse text normalization ("twenty five" → "25"); bails on ambiguous/year-like runs. |
| `dictionary` | table | `include_global` + `words[]`. |
| `replacements` | table | `include_global` + `rules[]` of `{heard, replace, regex}`. |
| `[ai_rewrite]` | table | Absent ⇒ no rewrite. `connection`, `prompt`, `fragments[]`, `context`. |
| `ai_rewrite.context` | inline table | `{ app, preceding_text }` booleans. `preceding_text` sends bounded text before the caret (native-only, best-effort via AX). (URL is a routing key only — `constraints[].url_pattern` — never sent to the LLM.) |
| `insertion` | enum | `paste` (default) \| `insert` \| `type`. `type` synthesizes real keystrokes for a target that ignores a synthesized paste (a VM guest): each character is mapped to a virtual key through the active keyboard layout, with shift/option posted as physical key events — the only form a hypervisor can deliver, since it translates the event's key code and drops its Unicode payload entirely (verified in VMware Fusion: payload events arrive as keycode 0, a literal `a`, even one character per event). Characters the layout cannot produce (emoji, composed accents) fall back to Unicode-payload events, which land in native apps but never in a guest. `type` touches the clipboard not at all — so `paste_key`, `copy_key`, `clipboard_sync`, and `paste_settle_ms` are **all ignored** under it; setting them alongside it does nothing. The insert holds the dictation in its inserting state for the whole run; a trigger pressed during that window is refused with the error sound. |
| `trailing` | enum | `none` \| `space` \| `newline`. Literal text appended to the transcript, inside the atomic insert (one ⌘Z still undoes it all). New modes created in Settings default to `space`; omitted TOML decodes as `none` for compatibility with existing config files. |
| `submit` | enum | `none` (default) \| `return` \| `shift_return` \| `cmd_return`. A keystroke synthesized after a **verified** insert (outside the undo atom). Never fires on a clipboard fallback — the text never reached the target. |
| `trim_trailing_punctuation` | bool | `false` (default). Strip a final `.` `!` `?` (and trailing whitespace) from the result, applied to the restored final string **before** `trailing` appends its suffix. Deterministic enforcement for command/identifier/subject-line modes (e.g. seeded **Shell** ships `true`) that should not end in sentence punctuation — the rewrite prompt can request this but cannot guarantee it. Closing quotes/parens/backticks/fences are left untouched. |
| `paste_key` | string | `command+v` (default). The chord posted to paste an insert, in the **same grammar as `trigger_keys[].key`** (`control+shift+v`, `ctrl+y`, aliases `cmd`/`ctrl`/`alt` accepted) — including its layout resolution, so a printing key is posted at whatever position types that character on the **host's** active layout; a chord the active layout cannot produce is logged and not posted, so the insert fails visibly rather than landing on the wrong key. A guest or remote session reads that position with its own layout, so it must match the host's (a Dvorak host driving a QWERTY guest posts the Dvorak position). Must be a chord — the trigger-only descriptors (`fn`, `left_command`, `mouse3`) are rejected. An unparsable value falls back to `command+v` at runtime but is **kept verbatim in the file** so a typo stays visible instead of being erased on the next save. Governs the paste keystroke only, never `submit`; ignored under `insertion = "type"`, which never touches the clipboard. TOML-only; no Settings UI. |
| `copy_key` | string | `command+c` (default). Same grammar and rules as `paste_key`, for the synthesized copy that captures a selection (`source = "selection"` modes). Selection capture in a guest or remote session is **best-effort** — the host-pasteboard bump it waits on is driven by that session's clipboard-sync, not the OS, so its timing is not guaranteed. |
| `clipboard_sync` | bool | Defaults to **on when `paste_key` has no ⌘**, off otherwise. When on, the scratch clipboard is written **un-concealed** (so a guest's or remote session's clipboard agent will pick it up) and is **never restored** — the dictated text stays on the clipboard, like a manual copy. Set it explicitly for a target whose client translates ⌘V for the remote side but still syncs the clipboard across the wire (RDP/Citrix/VNC): those clients fetch the clipboard back **at paste time**, so a restore racing that fetch would hand the remote app your previous clipboard. Setting it `false` alongside a non-⌘ chord restores the native behavior. Independent of the chord in both directions. |
| `paste_settle_ms` | int | `0` (default). Milliseconds to pause after writing the clipboard and before the paste keystroke. `0` = paste immediately (native apps — no delay). A positive value covers a **remote-session clipboard** (RDP/Citrix/VNC) whose eager cross-wire sync merely lags the paste, which otherwise pastes stale content; tune it up until paste is reliable. It cannot cover a target whose sync is **event-driven rather than lagging** — a local hypervisor (verified in VMware Fusion) syncs host→guest on window-focus changes, which never happen mid-dictation, so every settle value still pastes empty or one dictation behind; those targets need `insertion = "type"`. Independent of `paste_key` and `clipboard_sync` — a pure timing knob, applied to any paste, and ignored under `insertion = "type"`, which never touches the clipboard. TOML-only; no Settings UI. |
| `exclude_from_history` | bool | Skip writing this mode's dictations to history. |

There is **no "default mode"** setting. The **Direct** system mode (`_direct`, §"System modes" above)
is the single floor and owns Fn by default; the everyday mode is simply whichever mode is bound to Fn.
(Older `settings.toml` files may still carry a `default_mode_id` key — it is ignored and dropped on the
next write.)

The template a mode is created from sets `source` + `output`, and the mode editor shows the result read-only
on the summary's **Does** line; it offers no control to change it. A duplicate keeps it. The two-field model
stays in TOML for flexibility.

### Separate start and stop shortcuts

Use `press_style = "start"` and `press_style = "stop"` on different keys or pedal buttons. These
styles are configured in the mode's TOML file. Put the start entry first if you want Settings' single
shortcut well to edit it; later entries are preserved and described below the well.

| Action | Behavior |
|---|---|
| `start` | Starts a dictation using the normal mode-resolution rules. Further presses while busy are ignored, including during transcription or rewriting; they do not skip a rewrite. |
| `stop` | Finishes the current recording and processes its result, whichever mode or shortcut started it. During microphone startup it cancels the pending take. Once recording has ended, it does nothing. It never selects a mode to start. |

Both actions happen on key-down. Key-up does nothing, repeated key-down events while held are ignored,
and `tap_threshold_ms` has no effect on these styles.

**App constraints and switching apps.** Bundle constraints determine whether a mode's shortcuts are
registered while idle. Once a dictation is in progress, registrations stay unchanged until it finishes,
so a stop shortcut registered at the start remains usable after switching apps. Stop does not recheck
the owning mode's app, URL, or window-title constraints; any registered stop shortcut can finish the
recording. The mode and target remain based on the start-time context. If a different app is still
focused at insertion time, the result is copied instead of pasted into it.

**Reserved keys while idle.** A registered stop shortcut still reserves a keyboard chord or mouse
button when no recording is active: the focused app does not receive that chord or button. Modifier-only
shortcuts use the existing modifier handling instead. A URL- or window-title-only constraint cannot
release a binding outside its context; add a bundle constraint to limit registration to an app.

**Keep start and stop on distinct keys.** Do not give one key opposing actions in modes that can
register in the same app. The first registered binding determines the action; mode specificity does
not choose between starting and stopping. A conflict warning does not prevent use of that binding.

### Settings UI vs advanced TOML

The Settings UI exposes mode behavior in user-facing terms. Some fields stay available in TOML
without being normal editable controls because changing them casually can make a mode feel broken
or make global behavior hard to reason about.

| TOML field | Settings behavior | Why it is advanced |
|---|---|---|
| `insertion` | New and edited modes use `paste` in Settings. If a mode file sets `insert` or `type`, Settings shows a read-only note that a custom insertion method is active. | `insert` and `type` are compatibility escapes for unusual targets. They need Accessibility permission and can fail app-by-app, while `paste` is the predictable default. |
| `submit` | New and edited modes use `none` in Settings. If a mode file sets `return`, `shift_return`, or `cmd_return`, Settings shows a read-only note that the mode sends a key after insertion. | Submit keystrokes can send unfinished messages or commands in the target app. They are useful for deliberate automation modes, not casual editing. |
| `dictionary.include_global` | No per-mode toggle in Settings; global dictionary terms stay included by default. | Turning this off makes a mode stop using vocabulary the user expects to apply everywhere. |
| `replacements.include_global` | No per-mode toggle in Settings; global replacements stay included by default. | Turning this off creates surprising mode-specific replacement gaps. |
| `source` + `output` | Set by the template; shown read-only on the summary's “Does” line. | The app-supported selection workflow is the paired shape: capture the current selection and replace it with the rewritten result. |
| `trigger_keys[]` beyond the first, `tap_threshold_ms`, `press_style = "start"` / `"stop"` | Settings edits the first entry's key. Regular press styles use a picker; an existing `start` or `stop` style instead appears as read-only “Start only · configured in its TOML file” or “Stop only · configured in its TOML file.” Changing those styles requires editing TOML. Further entries show as read-only “Also starts with” / “Stops with” notes and are preserved when the first is edited. | Separate start/stop controls and additional shortcuts are advanced configuration; the shortcut well stays one control showing one binding. |

---

## Seeded starter modes

A fresh install writes **only `_direct.toml`** (the Direct floor). The starter modes below are
**templates**, not files: at first launch each catalog id is recorded in the seed ledger as an
**offer** (a `seed-ledger.toml` entry with a nil fingerprint), and the modes materialize on demand
from the Modes pane (Add Mode menu + template gallery) or when the first AI service connects
(Cleanup + Edit Selection). A materialized template written at its catalog id IS a seed — it keeps
`seed_id`/`seed_version` and gets a real ledger fingerprint, so unedited materialized seeds still
participate in seed updates; a second copy of the same template is a plain user mode (suffixed id, no
seed identity). They are ordinary mode files — nothing about them is special-cased in source — and the
user can edit or delete any of them. **Existing installs keep their previously-seeded starter files**
unchanged. Plain local dictation on Fn is provided by the **Direct** system mode (`_direct`, see
"System modes"). This set is the canonical one the menu and onboarding refer to (`ui_design.md` §6
menu bar).

| id | name | Shape | Rewrite |
|---|---|---|---|
| `polish` | Cleanup | `source = dictation`, `output = cursor`, trigger `right_option` | light cleanup (fillers, grammar, punctuation) that keeps wording and tone. Auto-enabled and connected when the first AI service is added; reachable on **Right-⌥**. |
| `message` | Message | `source = dictation`, `output = cursor` | **disabled by default.** casual chat-style message; no greeting/sign-off. A discoverable example enabled in Settings. |
| `email` | Email | `source = dictation`, `output = cursor`, phrase `as an email` | **disabled by default.** polished professional email with greeting + closing; never invents names/facts. A discoverable example enabled in Settings; once enabled, route to it by ending a dictation with **"as an email"**. |
| `edit-selection` | Edit Selection | `source = selection`, `output = replace_selection`, trigger `right_command` | transforms the selection from a spoken instruction. Auto-enabled and connected when the first AI service is added; reachable on **Right-⌘**. |
| `ask-about-selection` | Ask About Selection | `source = selection`, `output = speak`, best-effort redaction on, no trigger | **offered only while the `ask_about_selection` experimental flag is on.** Answers a spoken request about the selection in a few sentences, shown and read aloud; the selection is unchanged. |
| `ai-prompt` | AI Prompt | `source = dictation`, `output = cursor` | **disabled by default.** Cleans dictation into a clear instruction for an AI assistant, preserving technical terms; never answers it. Intended as a smart-model example. |
| `code` | Code | `source = dictation`, `output = cursor` | **disabled by default.** Cleans dictation for IDEs, code review, issues, commits, and coding assistants while preserving technical identifiers. |
| `markdown` | Markdown | `source = dictation`, `output = cursor` | **disabled by default.** Reformats dictation into raw Markdown (headings, bullet/numbered lists, bold, blockquotes, inline/fenced code) without wrapping the output in a code fence. |
| `shell` | Shell | `source = dictation`, `output = cursor` | **disabled by default.** Turns a spoken command or description into a single terminal-ready shell command, mapping spoken symbols ("dash dash", "pipe", "tilde slash") to shell syntax; emits only the command, never runs or explains it. |

The template catalog defaults (`enabled = false` in the catalog, `polish`/`edit-selection` carrying
Right-⌥/Right-⌘ and `email` carrying the "as an email" phrase) describe the mode a template
materializes into: materializing sets `enabled = true`, drops any trigger already held by an enabled
mode, and prefills the connection when exactly one exists. `message`, `ai-prompt`, `code`, `markdown`,
and `shell` are added from the gallery/menu when the user wants them.

The **Direct** system mode (`_direct`, shown to users as **"Plain Dictation"**) works with zero
configuration (it's the Fn default). When the first AI service is added, onboarding materializes and
connects `polish` and `edit-selection`; the remaining starters stay as templates for deliberate setup.
The default English engine plus **Direct** is the minimum first-run target (`ui_design.md` §2 first
run). Mode prompts instruct, never answer, keep redaction tokens intact, and avoid bracketed signature
placeholders.

### Seeded example replacements

Four starters ship worked **per-mode replacement rules** — ordinary, user-editable data in the mode's
`[replacements]` table, each teaching one technique behind a deliberate trigger phrase that plain
prose can't fire. The phrase language is uniform: point insertions say **"insert …"** (optional "a",
like the live-edit commands) and paired spans say **"begin …" / "end …"** (like verbatim):

| Mode | Say | Inserts | Teaches |
|---|---|---|---|
| `markdown` | "insert checkbox" | `\n- [ ] ` | `\n` output + boundary classes that absorb STT pause punctuation; `check ?box` covers both spellings |
| `markdown` | "insert horizontal rule" | `\n\n---\n\n` | the left class is `[\s,]*` (space/comma only) so a preceding sentence period survives |
| `markdown` | "begin/end bold", "begin/end italic" | `**` / `*` hugging the span | the smart-quote recipe (tips doc): the open marker hugs the next word, the close marker the previous one |
| `markdown` | "begin/end code block" (or "… code fence") | `\n```\n` | a symmetric block marker eats both sides so fences land on their own lines |
| `code` | "insert todo" | `\n// TODO: ` | `to[- ]?do` alternation for STT's "todo" / "to do" / "to-do" renderings |
| `message` | "insert shrug emoji" (or "shrug emoji") | `¯\_(ツ)_/¯` | the output is inserted verbatim; spoken alone it is a whole-utterance replacement and skips the rewrite |
| `email` | "insert sign off" (or "my sign off") | `\n\nBest,` | a closing with no name — edit the rule to add your own signature |

There is deliberately **no bare "begin/end code"** inline pair — "front end code" is everyday dev
prose and would false-fire; inline code stays a judgment call in the Markdown prompt. The prompts
pair with their rules: Markdown's no longer interprets spoken markers, it only preserves the Markdown
syntax the rules emitted (and still converts *implicit* structure — headings, lists, blockquotes,
inline code); Email's explicitly keeps a closing or signature already present in the dictated text
(the model is otherwise told never to add one). As with any replacement, output that flows into an AI
rewrite is not protected — only a whole-utterance match bypasses the model. Editing or deleting these
rules marks the mode edited and opts it out of future template updates, like any other seed edit.

### Seed reconcile & the `seed_version` discipline

Each starter carries `seed_id` (its catalog lineage) and `seed_version` (the catalog revision it was
written from). After the one-time seeding, every launch runs **seed reconcile** (`design.md` §5.1):
unedited starters are silently carried forward as the catalog drifts — renamed, newly added, or
**prompt-revised** — while hand-edited or deleted modes are never clobbered or resurrected. "Unedited"
is judged by a **template fingerprint** that excludes the `connection` and `enabled` user-knobs, so a
starter you connected during onboarding still receives updates; only editing its prompt/shape opts it
out.

> **Discipline:** whenever you change a starter's template in `starterModes()` (prompt, fragments,
> source/output, commands, trim), **bump that starter's `seed_version`**. The version bump is the *only*
> signal that carries the revision to existing installs — change the prompt without it and the
> improvement ships to fresh installs only, never to anyone already running. The
> `revisingAStarterTemplateRequiresAVersionBump` test pins each starter's `(seed_version, template
> fingerprint)` and fails on an un-versioned template change to enforce this.

> **Sequencing footgun:** never ship a starter's *first-ever* `seed_version` bump in the same release
> that introduces or changes the fingerprint scheme — split them across two releases. The first reconcile
> on an upgrading install writes that install's template fingerprint; a bump in that same pass has no
> baseline to match yet, so reconcile skips it (the self-heal needs the on-disk template to still equal
> the catalog, which a bump breaks). The mode is left on its *prior, still-working* prompt — no crash or
> corruption — but the revision never reaches that narrow population (upgraders who connected/enabled but
> never edited the mode). Fresh installs are unaffected. Let this introducing release settle the
> fingerprints first; bump in a later one and it lands cleanly.

---

## Referenced config files

### `connections.toml` — named LLM connections (BYOK)
```toml
schema_version = 1

[[connection]]
id = "gemini-flash-lite"        # referenced by modes
name = "Gemini Flash Lite"
provider = "gemini"             # "openai" | "anthropic" | "gemini" | "openai_compatible"
model = "gemini-flash-lite-latest"
key_ref = "keyscribe.llm.gemini-flash-lite"   # Keychain item id — the key itself never lives in TOML
# auth_method = "api_key"       # "api_key" | "token_command" | "none"; defaults to "api_key"
# base_url = "https://..."      # required for openai_compatible endpoints
# token_command = "..."         # required when auth_method = "token_command"
[connection.params]
temperature = 0.2
max_tokens = 2048     # base output room; raised per request for long content and when the model may reason
reasoning = "lowest"  # "lowest" | "model_default" | a level: "minimal" "low" "medium" "high" "xhigh" "max"
# output_ceiling = 32768  # written by Settings when the service publishes the model's output limit
```

**`reasoning` is provider-neutral; each provider adapter translates it.** Settings edits it as
**Reasoning**, and `max_tokens` as **Minimum output allowance**, with tokens as the unit. Both live under
**Rewrite settings**. The default `lowest` is labeled **Recommended — least reasoning**.

- **`lowest`** (the default on every provider) negotiates. The first request asks for reasoning off; when
  the service rejects that *value*, the client steps to the next lower-cost setting the provider family
  offers, jumping straight to the lowest value the error lists when it lists any. The setting that
  produced a reply is remembered for the connection, model, and endpoint, across restarts, until a request
  that starts from it fails or the app is updated. If no step is
  accepted, the model runs at its own default and that is reported. Read
  `ReasoningLadder.rungs(for:provider:)` for the steps.
- **A level** (`minimal`…`max`) is sent exactly. If the model rejects it, the rewrite falls back to local
  text with a reason naming the level; it is never quietly replaced by another level. The only retry is
  the same level in another wire shape (a Gemini model that has no `thinkingLevel` gets the equivalent
  `thinkingBudget`).
- **`model_default`** sends no reasoning setting at all.

A service that rejects the reasoning *parameter itself* (unknown field) is recorded as **couldn't be set**,
not as "reasoning off": the model may still reason, so the extra output room stays on. Only a reply that
reports an explicit reasoning count of zero confirms no reasoning; a reply that reports reasoning tokens or
reasoning text after a request for none, or from a service that could not take the setting, is recorded as
**not honored** or **reasoned on its own**, and a reply with no count at all leaves the setting
unconfirmed. A dropped setting the service never confirmed, a model that reasoned anyway, and a ladder that
ran out are announced on the completion HUD once per connection and model each launch; a model that took no
setting and reported zero reasoning produces no notice. An accepted "off" the service does not confirm is
recorded as requested, not as verified. Every History entry names where reasoning landed. OpenRouter
requests that carry a reasoning setting also send `provider.require_parameters = true`, so a route that
would silently ignore the setting is skipped. When that leaves no route ("no endpoints … requested
parameters"), the router does not say which parameter was the problem, so the reasoning setting is not
blamed. The retry first drops temperature and keeps the reasoning setting required. If that still finds no
route, a level the person chose fails the rewrite with that reason rather than being sent unenforced, and
**Recommended — least reasoning** stops requiring every parameter and is recorded and announced as **not guaranteed**.
A bare "no endpoints" for the model is an availability failure and is not retried.

`max_tokens` is the base room for the visible answer. Long content raises it per request (prompt_design.md
budget policy), and a fixed extra room is added whenever reasoning is not proven off — reasoning and
answer share one limit on every provider, so this is headroom, not a reservation. A ceiling the service
publishes for the model (`output_ceiling`), or one a too-large-value error names, caps the result.

Older files are read as before: `reasoning_effort = "none"` and `gemini_thinking_level = "minimal"` mean
`lowest`; any other value of either becomes that exact level, `xhigh` and `max` included. Neither key warns
as unknown, and the next save writes only `reasoning`. Reasoning text the model returns
(`reasoning_content`, `message.reasoning`, `<think>` blocks) is never pasted; it is read only as evidence
for the failure reason below.

When a reply stops at the output limit before any answer text, History and the HUD say *"The model reached
its output limit while reasoning…"* only when usage or reasoning text shows the model reasoned, and
*"The reply hit the output limit before any answer text…"* otherwise. A Responses reply marked incomplete
is attributed to the limit only when it says `max_output_tokens`; any other or missing reason is reported
as an incomplete reply. Use
**Test** in the connection editor to see where reasoning landed for a model before dictating.

The editor's hosted quick-setup presets (OpenRouter, Groq, Mistral) are **not** distinct providers on
disk — each persists as a `provider = "openai_compatible"` connection with the preset's `base_url` and a
lightweight default `model` (e.g. OpenRouter → `https://openrouter.ai/api/v1` /
`google/gemini-3.1-flash-lite`, Groq → `https://api.groq.com/openai/v1` / `openai/gpt-oss-20b`,
Mistral → `https://api.mistral.ai/v1` / `mistral-small-latest`). The preset only seeds the draft so the
user just adds a key; reopening the connection recovers the preset from its base URL.

`auth_method` controls how requests are authenticated:

| `auth_method` | Meaning |
| --- | --- |
| `api_key` | Read the secret from Keychain using `key_ref`. Hosted providers require this. OpenAI-compatible endpoints may use it when a proxy expects a bearer token. |
| `token_command` | Run `token_command` before requests and send its output as `Authorization: Bearer …`. While you record in a mode that uses the connection, a token that is missing or about to expire is fetched ahead of the request. The generated token is kept in memory only and never written to disk. |
| `none` | Send no Authorization header. Valid for local/no-auth OpenAI-compatible endpoints. |

For OpenAI-shaped connections, KeyScribe automatically selects the compatible request format for each model
endpoint. What a service accepted (the wire, and any field it made the request drop or rename) is kept in
`<support folder>-request-adaptations.json` and `<support folder>-wire-overrides.json` beside the support
folder, so the first rewrite after a restart does not relearn it. An entry is keyed by connection id, model,
base URL, wire, and reasoning setting, and is dropped when a request that starts from it fails for any reason
the client cannot adapt to. Each file is stamped with the app version that wrote it, and a different version
starts empty, so every update relearns once. The files hold no prompt or reply and nothing read from Keychain or a token command;
a base URL is stored as written, so one with a credential in it is copied here just as it sits in
`connections.toml`. **Erase All Data** removes both files; deleting them by hand only costs the relearning. Responses requests map the rewrite system instruction to `instructions` and the user text to `input`,
send `reasoning.effort` when a reasoning step is in play, and size `max_output_tokens` by the same output
room rule as Chat. Every Responses request is stateless — `store = false` is load-bearing for privacy and is never
dropped: an endpoint that rejects it fails the rewrite rather than silently allowing server-side storage. A
gateway that rejects `reasoning` steps or drops it by the rules above. KeyScribe reads typed
`output_text` content and treats an incomplete response as a rewrite failure, preserving the existing validation,
retry, and local-fallback path.

`token_command` stdout may be a raw token on the first line, `Bearer <token>`, OAuth-style JSON
(`access_token`, `token`, or `id_token`), or Kubernetes ExecCredential-style JSON
(`status.token`). If stdout includes `expires_in`, `expiration`, `expires_at`, or
`status.expirationTimestamp`, KeyScribe honors that expiry with a short refresh skew; otherwise the
token is cached in memory for five minutes to avoid re-running the command for every rewrite.

### `fragments/<id>.md` — shared prompt fragments (one file per fragment)
Prose lives best as a markdown body with a small YAML header; structured config stays TOML.
```markdown
---
schema_version: 1
name: My Voice
---
Write in my voice: warm, terse, plain. Spell out contractions.
```
Fragment id = filename stem (`my-voice`). The body is the fragment text, appended verbatim.

### `dictionary.toml` / `replacements.toml` — global sets
```toml
# dictionary.toml
schema_version = 1
words = ["KeyScribe", "Parakeet", "Anthropic"]
```
```toml
# replacements.toml
schema_version = 1
[[rules]]
heard = "teh"
replace = "the"
regex = false
```

### `vocabularies/<id>.toml` — shared vocabularies

A named set of words and replacements that the modes listing it use together. The id is the file name
and never changes, so a rename keeps every mode's connection.
```toml
# vocabularies/programming.toml
schema_version = 1
name = "Programming"
words = ["Kubernetes", "Postgres"]
[[rules]]
heard = "pain"
replace = "pane"
regex = false
```
A mode uses one by listing its id: `shared_vocabularies = ["programming"]` (omitted when it uses none).
Plain Dictation never uses one. Precedence: a mode's own entries override shared entries, and shared
entries override Global. A replacement overrides another with the same heard phrase and rule type; a
word overrides another with the same letters ignoring case. When two shared vocabularies a mode uses
disagree, Settings asks the user to settle it with a rule or word of the mode's own; in a
hand-edited file, the vocabulary listed first wins. `include_global` affects Global only, never shared
vocabularies. A shared vocabulary file that fails to load keeps its last good version while the app
runs, and is reported like any other config file. Replacement use counts are kept per vocabulary.

### `voice_commands.toml` — saved commands for Voice Commands (experimental)

Read only while the `voice_commands` flag is on. The Voice Commands mode understands
an app-switching verb followed by a target (`VoiceCommandGrammar.focusVerbs`), `run <action> [words]`, `go back`,
`repeat that` or `say that again` (`VoiceCommandGrammar.repeatSummary`, which replays the last spoken reply of the
Coding agent feature), and `cancel` or `never mind` (`VoiceCommandGrammar.cancel`, which runs nothing), matched against
the whole utterance (case and punctuation ignored, and a leading or trailing `please` ignored around a recognized
command, though not before a sound-alike prefix; a leading "the" is dropped from an app-switching target, so
`switch to the browser` looks for `browser`, but not from a `run` action name). The app-switching prefixes also accept
`which to` and `witch to` for `switch to`, and `two` or `too` in place of `to` after `switch`, `which`,
`witch`, or `go`. These are exact prefix alternatives, not transcript replacements: target names,
action input, and the original heard text are preserved. They apply equally to live commands and
**Preview a command**. Other command words, including `run` and `go back`, have no sound-alike alternatives.
The verbs differ in what they may start. An opening verb (`VoiceCommandGrammar.openingVerbs`) may start
an app, load a saved link, or start an app before searching inside it. A switching verb
(`VoiceCommandGrammar.runningVerbs`, sound-alikes included) reaches only a running app, an open window, or
an open tab. After a switching verb, an app that is not running is reachable only by an exact name, which
answers with the phrase that would open it; it never takes part in partial, any-order, or near-miss
matching, so it cannot take a phrase from something open. A saved place, link, or tab search is reached
only after a verb and takes that verb's limit: `switch to` on a saved app does not start it, and on a saved
link it reuses a matching open tab or says none is open. A saved script or shortcut is reached only after
`run`. A saved name said on its own runs and opens nothing and answers with the phrase to say (`open
reading list`, `run new note buy milk`), so no saved name, even one that starts with a verb or equals a
built-in phrase, can take over a built-in command. `go back` never starts an app.
An app answers, in every tier, to the name shown in the Applications folder and to the name in its own
menu bar when the two differ; the name KeyScribe shows and sorts by is the Applications-folder one.
A target is a running app, an app installed in an Applications folder (or one folder down inside it),
or a saved command from this file. The file is one ordered list of `[[command]]` tables; each does
exactly one thing, chosen by which of `app`, `url`, `find_tab`, `run`, or `shortcut` it sets:

```toml
schema_version = 1

[[command]]
id = "3f2a9c1e-…"                # stable and never shown; Settings writes a random one. Optional when written by hand
name = "Mail"                    # display name; also always a spoken name. Unique, ignoring case.
say = ["male", "email"]          # optional misheard form or preferred nickname
app = "com.apple.mail"           # bring this app forward; on its own or after "open", start it if needed

[[command]]
name = "Gmail"
url = "https://mail.google.com/" # focus an open tab whose address starts with this; else open it, except after "switch to" (or an app link — below)
browser = "com.google.Chrome"    # optional: only look in, and open with, this browser

[[command]]
name = "Web Hooks"
url = "slack://channel?team=T0123ABCD&id=C0456EFGH"  # an app link: opened as-is in its app

[[command]]
name = "Chrome"
find_tab = true                  # a tab search: "chrome gmail" finds Chrome's tab titled like "gmail"
browser = "com.google.Chrome"    # optional: only search this browser; absent = every browser

[[command]]
name = "Deploy"
say = ["ship"]                   # optional extra spoken names
run = ["~/bin/deploy", "--env", "{text}"]  # a program, then its arguments

[[command]]
name = "Journal"                 # a macOS Shortcut: same naming and matching as a program
shortcut = "Journal Entry"       # the shortcut's name in Shortcuts
shortcut_id = "6E982466-2036-4362-BDEC-983051029F6A"  # optional: run by identifier, so a rename still works
input = "{text}"                 # optional text given as the shortcut's input
```

Settings lists the commands in file order under **Commands**. `browser` applies to `url` and `find_tab`
commands; `shortcut_id` and `input` apply only to a shortcut. **`id`** identifies the command
across renames and edits: Settings edits, deletes, and remembers a pending choice by it, never by name.
A command written without one gets an id derived from its name, which the next save from Settings keeps.
Two commands may not share an id or a name. In what follows, a *place* is a command that opens an app,
link, or tab, and a *script* one that runs a program or shortcut.

**Scripts** run a program when you say **run** and their name, and can be handed what you say after it:

- `run` is the program followed by its arguments. The program is a full path (`/…` or `~/…`); it is run
  directly, never through a shell, from the home folder, with standard input, output, and error not
  connected to anything you see (standard output is read only for the report lines below), and the
  environment KeyScribe itself was started with. Opened from Finder or
  at login, that `PATH` holds only the system folders. Each argument is passed exactly as
  written, except that `{text}` is replaced by the spoken text inside that argument: the words never
  become extra arguments, and KeyScribe never evaluates them. `{text}` may not appear in the program.
- **Matching** follows the saved-name rules below: one of the script's spoken names in whole words right
  after **run** (`run deploy staging`), where only scripts are considered. The name alone (`deploy
  staging`) runs nothing and answers with the phrase to say. An app-switching word never runs a script, and
  **run** never opens an app or place. The spoken name is independent of the executable's filename: `name = "Foo"` can point at
  `~/bin/bar.sh`. A script whose arguments use `{text}` needs words after its name; saying only the name
  fails with a message and runs nothing. A script without `{text}` fails with a message when more words
  follow its name. A script is never matched by a near-miss, and the dictionary never corrects its name; it
  does correct the words after the name, unless that would change which command matches. These matching rules apply after mode replacements.
- **The text** is what follows the spoken name, in the cleaned transcript's own case and punctuation, with
  leading and trailing spaces and the `, ; : . ! ? …` that speech recognition adds at the edges removed.
  The voice-commands dictionary never corrects it.
- **Shortcuts** run through `/usr/bin/shortcuts run`, by `shortcut_id` when it is set and by name
  otherwise. `input`, with `{text}` replaced by the spoken text, is written to the shortcut's standard input,
  which the shortcut receives as text; without `input` it receives nothing. An `input` containing `{text}`
  needs words after the name, exactly like a program argument. A failure shows the shortcut's last error
  line, without an exit status. A shortcut can wait on a question (Ask for Input, Choose from Menu, an
  alert, or a first-run permission prompt), so the late reporting below matters most for shortcuts.
- **Running:** the command waits up to about a second and a half. An action that exits with status 0 then
  is done. One still running is shown as started (*Started, still running* in the HUD, *Command started*
  in History) and is left to finish, with no time limit, so a shortcut waiting on your answer is never
  stopped. When it does finish, its History entry is updated to the final result, and a failure is shown in
  the HUD unless a dictation is in progress. A result arriving after KeyScribe quits is not seen, so that
  entry stays *Command started*. A nonzero exit fails the command, showing the exit status and the last
  line the script wrote to standard error. A program that is missing or not executable fails without
  starting. The script's arguments and output are never logged. Standard output is never kept beyond the
  report lines below; with history on, History saves the command line, arguments included, a failure's
  message, which can carry the last line the script wrote to standard error, and a reported message (see
  *History records* above). A newly written or edited file can take longer to start the first time, while
  macOS checks it.
- **Reporting results.** A program can tell you what happened by writing lines that start with one of
  these markers to standard output. Every other line is ignored, so a script that prints nothing of the
  kind behaves exactly as before. The exit status still decides whether the command failed. Shortcuts
  cannot report this way.

  | Line | Exit status | What you see |
  |---|---|---|
  | none | 0 | The script's name, as a completed command |
  | `::done::<message>` | 0 | The message as a completed command, with the script's name under it |
  | `::info::<message>` | 0 | The message as a neutral notice, with no failure styling and no exit status |
  | `::choice::<value>⇥<label>` (one line each) | 0 | *Which one?* listing each label, answered like any other choice |
  | none | nonzero | `<name> failed (exit N): <last standard error line>` |
  | `::done::` or `::info::` | nonzero | `<name> failed (exit N): <message>`, in place of the standard error line |

  `⇥` is a tab. A choice line without a tab uses its text as both value and label, and a repeated value is
  listed once. When several messages are written, the last one counts. A long message or label is shortened.
  Choices win over a message from the same run, and they are ignored on a nonzero
  exit. When a choice is answered, by voice or by click, the script runs again with the **same arguments**
  and the chosen value in the environment variable `KEYSCRIBE_CHOICE`; that run reports like any other,
  and can offer a new choice. The number you say is never passed. Cancelling, a new command, or the
  choice timing out runs nothing, so a script never learns that a choice was dismissed. A run offers a
  choice only if it finishes within the wait above; one that is still running when the wait ends and
  then writes choice lines fails with *<name> took too long to offer a choice*. A run offering more
  choices than *Which one?* can list fails and asks you to narrow them down. A reported message from a
  script that finishes late is still shown, under the same rule as a late failure.
- **Interpreters cannot take `{text}`.** A script whose program has a known interpreter file name, such
  as `sh` or `env`, including a version suffix like `python3.12`, is refused when any of its arguments
  contains `{text}`, because `/bin/sh -c {text}` would run spoken words as shell commands. The name is
  checked as written and after following symbolic links, so a link to `/bin/zsh` under another name is
  refused too. For a known wrapper program (such as `nice`, `nohup`, `xcrun`, or `timeout`), the rule
  checks the program the wrapper launches, skipping the wrapper's own options, so `nice /bin/sh -c {text}`
  and `xcrun swift -e {text}` are refused while `nice ~/bin/record --category python {text}` is not. The rule also refuses an interpreter given a script file
  (`/bin/sh ~/bin/note.sh {text}`); instead, start that file with a `#!` line naming its interpreter and
  any options it needs, make it executable, and choose the file itself as the program. An interpreter
  without `{text}`, such as `osascript -e` with fixed code, is allowed. The editor will not save a refused
  script. One that is already in the file still loads with everything else, but saying it runs nothing
  and shows why. The rule prevents a common mistake; it does not make other programs safe. A copied
  interpreter, a wrapper the rule does not know, or a script that runs its input as code (`eval "$1"`)
  can still run spoken words as code, so write scripts that treat the text as data, as in `"$1"` below.
- **An invalid entry rejects the whole file**, like any other validation error in it: when KeyScribe
  starts with such a file, no saved commands are available until it is fixed (apps still open
  by name), and while KeyScribe is running it keeps the last version that loaded. The Voice Commands
  editor names the offending entry and why it is invalid. Fix or remove that entry in
  `voice_commands.toml` and save; the file is read again automatically.
- **Editing this file from another program.** It is TOML, and any valid TOML is accepted: a string can
  be written in any of the forms the [TOML specification](https://toml.io/en/v1.0.0#string) allows. Saving
  from Settings rewrites the whole file in KeyScribe's own layout, which may change quoting, key order, and
  spacing, and drops comments. Saving re-reads the file first and changes only the entry being edited, so
  an edit made outside the app before the save starts is kept; an edit to an entry that has been
  removed is refused rather than bringing it back. A program that edits the file at the same moment can
  still be overwritten. So a tool should parse the file with a TOML library, change only its own entries,
  keep every `id` and every entry it does not own, and write the result back, never search and replace
  text. Give each entry the tool owns a fixed `id` of its own and find it by that `id`, not by name, since
  the person can rename it in Settings. Change only the fields the tool sets, so the person's other
  names (`say`) survive. For example, in Python 3.11 or later with the `tomli-w` package:

  ```python
  import pathlib, tomllib, tomli_w
  path = pathlib.Path.home() / "Library/Application Support/KeyScribe/voice_commands.toml"
  data = tomllib.loads(path.read_text())
  commands = data.setdefault("command", [])
  mine = next((c for c in commands if c.get("id") == "my-tool-note"), None)
  if mine is None:
      commands.append({"id": "my-tool-note", "name": "Note", "run": ["~/bin/note", "{text}"]})
  else:
      mine["run"] = ["~/bin/note", "{text}"]
  path.write_text(tomli_w.dumps(data))
  ```

- **A complete example.** A file `~/bin/note` containing

  ```sh
  #!/bin/sh
  printf '%s\n' "$1" >> "$HOME/notes.txt"
  ```

  made executable with `chmod +x ~/bin/note`, and the entry

  ```toml
  [[command]]
  name = "Note"
  run = ["~/bin/note", "{text}"]
  ```

  turns "note buy milk" into `~/bin/note "buy milk"`, which appends `buy milk` to `~/notes.txt`.

- **What is matched is the cleaned transcript.** Before anything is matched, the Voice Commands mode's own
  replacements run over the whole utterance, so one can repair other misheard verbs
  (`stitch to Mail` → `switch to Mail`).
  Then its dictionary fixes near-misses in the **target and in the words after a saved command's name** —
  never in the command words or the name itself, so a term like `Lunch` cannot turn "launch Safari" into
  something that no longer parses — which lets a target keep its real spelling (such as `Spotify`) and the
  words a script receives get the same spelling fixes as dictation. A correction that would change which
  saved command the words name (say "Deploy postgrass" becoming the separate command "Deploy Postgres") is
  not applied, and a whole-utterance replacement's own text is never corrected, only the words it captured. Dictionary correction is best-effort and excludes terms shorter
  than four normalized characters. A replacement that owns the whole utterance becomes the command,
  which makes custom spoken shortcuts (`code` → `open Visual Studio Code`). A terminal `<CR>` on a
  regex replacement is dropped, since a command never presses Return; a literal replacement keeps `<CR>`
  as written, as everywhere else. On a speech model that can steer recognition, the dictionary steers it
  too, and so does every saved command's `name` and `say` entry: they are read from this file each time it
  loads, used only while the Voice Commands mode is listening, never added to any word list, and gone when
  the command is. The recognition-bias switch for the engine turns both off. On a speech model that cannot
  steer recognition, a saved name helps nothing before matching; use `say` or a replacement for a name that
  is often misheard. Global vocabulary applies here as in every mode. A file written before that default carries the
  seeded `include_global = false`; it is switched on once, at the first launch of a build that has this
  default (not when the feature is turned on), and recorded in the seed ledger, so a later hand edit back to
  `false` is kept. A `false` written by hand before that launch is switched on too, since it cannot be told
  apart from the seeded one.
- **A repeatable mishearing** can be repaired in **Settings ▸ Vocabulary ▸ Voice Commands** with a
  literal replacement: **Word or heard phrase** `switch to male`, **Use instead** `switch to Mail`,
  with **Match heard phrase as a regular expression** off under **Advanced**.
  A full-command rule avoids changing the common word `male` elsewhere, including in words passed to
  scripts and shortcuts. Alternatively, the Mail place above accepts `male` and `email` as spoken names, so both
  `switch to male` and `open email` reach Mail without rewriting the transcript. Keep these fixes in the
  mode's vocabulary unless you deliberately want other modes to use them. See the
  [worked examples in the FAQ](../../FAQ.md#a-voice-command-keeps-being-misheard).
- A command sets **exactly one** of `app`, `url`, `find_tab = true`, `run`, or `shortcut`. An older
  `sidebar = "<bundle id>"` is read as `app` for the same bundle id and written back as `app` on the next
  save; a command that sets both is rejected. `url` is an `http`/`https` address, or a link that opens an
  app (`slack://…`, `obsidian://…`): any other scheme except `file`, `javascript`, `data`, `blob`, `about`, and
  `ftp`, with no username or password. An app link is opened as written by the app macOS assigns to it; it is
  never matched against open tabs, never reads them, and cannot set `browser`. If no app opens it, the command
  fails and opens nothing. A file that breaks a rule
  fails to load as a whole and the last good copy stays in effect (surfaced like any malformed config file).
- **Saved names come first.** Every place and script is checked before any command word, against the
  start of what was said, in whole words, the same way for every kind of command
  (`VoiceCommandResolver.savedMatch`): `Web hooks` answers "web hooks", not "webhooks"; add `webhooks` to
  `say` for that. Only navigation targets reached through a verb (apps, windows, tab titles) are matched
  loosely. The **longest matching spoken name wins**
  whatever the file order, so `Note` and `Note work` both work and "run note work buy milk" runs `Note work`.
  Only then are the words after it checked: a script or shortcut with `{text}` needs some, a tab search
  uses them to find the tab, an app place uses them to find something in its app (below), and anything else
  must have none. When the check fails the command explains
  and runs nothing; it never falls back to a shorter name. Names tied for longest are offered as a numbered
  choice. Names match exactly, never by a near-miss. Any phrase can be a name, including one that starts
  with a command word (`go home`, `open notes`); because a saved name is reached only after its verb
  (`open go home`, `run open notes`), no name can catch a built-in command. A place and a script may share a
  name, since their verbs tell them apart. A tab search is reached after `open` or `switch to` and its name,
  with the words to find after it (`switch to chrome github`), unless a longer saved place name also matches
  (`open work docs` opens the place `Work docs` rather than searching the tab search `Work` for “docs”). A
  tab search and a place tied on the same name are offered as a numbered choice.
- **Tab searches** (`find_tab = true`) look only at tabs in their `browser`, or in every running browser that
  can list tabs when `browser` is absent, using the same title matching as an open browser tab below (exact,
  then a run of words, then words in any order or a near-miss). A tab is also known by its **site**, the
  `http`/`https` host without `www.` or its top-level domain (`grafana.example.com` → "grafana example",
  `bbc.co.uk` → "bbc"); the site is tried after the title at each step, so a tab titled "Dashboard" is found
  by "grafana", and a title match beats a site match. Tabs tied at the winning step are never offered as a
  choice when they are all in one browser: the one in that browser's frontmost window that has a match wins,
  leftmost first, however many there are. Window order is per browser, so ties across browsers are still
  offered as a choice. An older `quick_switch` key, which used to turn this on, is read and ignored, and is
  dropped on the next save. Said alone, a tab search with a `browser`
  brings that browser forward; one without asks for words to find. Reading tabs uses the same Automation
  permission as a web place.
- **Finding items in apps** is experimental and runs only while the `Feature.findInApps` flag is on. An app's
  name or an app place's spoken name, followed by more words, searches that app for the rest: "open slack
  general", or "work general" when a place named `Work` opens Slack. Nothing has to be saved for an app's
  own name. The app is chosen first, by the longest name at the start of the phrase: a place's spoken name
  over a running app's over an installed app's, so a place can stand in for an app ("sublime" opening
  TextEdit), and Settings warns when a place's name is also an installed app's. Apps sharing that name are
  offered as a choice before anything is read. Then only that app is searched; nothing falls back to other
  apps' windows or tabs. A browser that can list its tabs (`installedSnapshot().tabBrowsers`) is searched by
  its open tabs, with the tab-search matching above. Any other app is first searched by the titles of its
  open windows (exact or a run of words, as for windows above) when every app listed its windows, so "open numbers budget" still focuses an open
  "Budget — Numbers" window; only when none matches is it searched by the entries listed in the
  sidebar of its front window: the leftmost outline it shows, such as chat channels and people, mailboxes,
  or note folders. An entry is named by the text it shows, not its unread count or badge, and grouped under
  the row or level above it ("Channels", "Direct Messages", an account). Matching is the tab-title matching
  above (exact, a run of words, words in any order, or a near-miss), and entries tied at the winning step
  open the first in sidebar order, without asking; "go back" returns to where you were if it was the wrong
  one. Only entries the app
  shows are found, so a collapsed section or a long list that draws only its visible rows can hide one, and
  a failed search says so. The sidebar is read through Accessibility only when such a phrase is said; it is
  never read in the background, and Settings' preview never reads one. An app built on Electron whose
  sidebar is not exposed has its accessibility support turned on first (`AXManualAccessibility`), which
  stays on until that app quits. After an opening verb, an app that is not running, a browser included, is
  started first, and its
  sidebar or tabs are read again for a bounded time (`VoiceCommandRunner.launchWaitSeconds`; no new read starts after it, but a read already under way keeps its own short limit, so the wait can run a few seconds past it) while the
  HUD says it is opening the app and then looking in it. A sidebar that stays empty for a few reads in a row
  (`VoiceCommandRunner.emptySidebarSettleReads`) is taken as empty and reported as having no match; one that
  never appears is reported as not ready yet. Cancelling or replacing the command stops this:
  an app not yet opened is not opened, and no further reads are made, but an app that already started stays
  open. After a switching verb nothing is started: an app that is not running, or that quits while it is
  being read, is reported instead. Settings' preview and `--voice-command` never open an app.
  A sidebar that could not be read in full (it lists more than `SidebarOutline.itemLimit` entries, or the
  read was cut short) is still searched as read, and a match opens without asking. A sidebar whose window cannot be identified is not read, and an entry opens only in the
  window it was read from, and only if it is still at the same place under the same group; otherwise the
  command fails and opens nothing. Opening presses the element that shows the entry's name, or selects the
  row; it never presses a disclosure triangle, checkbox, or button, never types or sends anything, and stops
  before each step once the command is abandoned or has run out of time. Afterwards it confirms the open
  when the row reports itself selected or the window title names the entry (`SidebarOutline.confirms`);
  otherwise the result says the entry was pressed but could not be confirmed. While the flag is off, an app
  place takes no extra words, and the app's name with extra words is matched as a whole like any other
  target. While it is on, the exact names in the matching order below (a place's, a running app's, an
  installed app's) come first, then an app's name followed by more words, and only then the partial
  matches, so "open mail inbox" searches Mail even beside a running app called Mail Inbox Helper.
- **Matching order** for an app-switching verb while finding items in apps is off (the change when it is on is
  described above), first hit wins: a place's spoken name exactly; a running app's name exactly; a
  contiguous run of words in a running app's name ("chrome" → Google Chrome); an installed app's name
  exactly; the same partial rule on place names, so a place named "Mail Check" never takes "open mail" from
  Mail; then an **open window's title**, exactly and then as a
  contiguous run of words; then an **open browser tab's title** the same two ways, then its **site** the same
  two ways; then installed apps partially. Only if nothing matches is the target matched fuzzily against every one of those: a
  near-miss is snapped, using the dictionary's fuzzy rule, against places, running and installed apps,
  window titles, and tab titles and sites, and a name or title also matches when it contains every spoken word in
  any order ("strava run" → `Afternoon Run | Run | Strava`). The fuzzy step runs the tiers above in the
  same order, so a fuzzy hit on a place still beats an equally close one on an app, window, or tab.
  After a switching verb, installed apps that are not running, places for them, and saved links with no
  matching open tab (an app link always) are left out of the partial, any-order, and near-miss steps; a
  saved link that partly matches is checked against the open tabs before it can take part.
  Different targets tied at the winning step are offered as a numbered choice and nothing runs until one
  is chosen, except tabs tied in one browser, which go to the frontmost as in a tab search; above `VoiceCommandChoice.displayLimit` targets the command fails and asks for more of the
  name. Places and actions keep their configured order in the choice, apps are sorted by name. A
  near-miss picks the closest target; targets tied for closest go through the same order, so a place
  still beats an app equally close, and two tied at the same step are offered whatever order they are
  listed in. Saved commands may share a spoken name on purpose (that is how to get the choice), so a
  shared name is an advisory in Settings, never a load error; primary names must still be unique. The
  advisory compares names the way they are matched: places by the same spoken-name match `open` uses (so
  `Work Mail` and `Workmail` clash), scripts and shortcuts word by word, and only against commands reached
  by the same verb. Settings also points out, while
  editing, a longer saved name that takes over some of what a command taking words would receive, a new
  longer name that takes words away from an existing command that takes them, and a preview phrase
  that, after the mode's replacements, another saved command would answer or no saved command would
  (`VoiceCommandConfig.conflicts`, `VoiceCommandExample`).
- **Window titles** are read over Accessibility on this Mac, and only when no place or app name matched
  first, so an exact app name (`open Slack`) never looks at windows. A title matches exactly when the
  spoken target equals the whole title or one of its parts: apps put the document, project, and app name
  in one title between separators such as a spaced dash or a pipe (`WindowTitle.segments` holds the
  rule). Only standard windows with a title are matched, minimized ones and those of hidden apps included; sheets,
  panels, and dialogs are not, nor are this app's own windows. macOS lists only the windows on the
  current desktop, so a window on another desktop or in another full-screen app cannot be found from
  here, though its app's name still works. A browser window is matched by its current tab's title, since
  that is the window's title, and wins over that same tab. A choice between windows names each one's app,
  and the document or site when two titles are the same.
- **Tab titles** are read from every running browser whose tabs can be listed (see *Tab matching* below),
  only when no place, app, or window matched first, and are split into parts like window titles. Reading them
  uses the same Automation permission as a web place, so the first such command can be what asks macOS for it;
  a browser that refused or did not answer contributes no tabs. If the tabs cannot be read in time, the command
  fails rather than choosing from the rest. A choice between tabs names each one's browser and site. A tab is
  focused by its address, re-checked just before it moves; if it has closed, the command says so and opens
  nothing.
- **If any app does not answer when its windows are read**, the command fails without opening anything
  (`Could not check all open windows. Nothing was opened. Try again.`) rather than choosing from the
  windows that did answer. When Accessibility is off, the command says so and offers its settings.
- **A window is brought forward by identity, never by title.** The choice made when the command was
  heard is re-found in the same process just before it moves; if it has closed, the command says so and
  brings nothing else forward, and if the app does not answer it fails without trying anything else. A
  step already taken (a window unminimized, say) is not undone when a later one fails.
- **Tab matching** ignores the scheme, a leading `www.`, the host's case, and trailing slashes, and respects
  path boundaries (`mail.example.com` never matches `mail.example.community`). The path, query, and fragment
  keep their case: `example.com/Project` does not match a tab on `example.com/project`. Only browsers whose
  scripting dictionary describes tabs are asked; any other browser has its page opened directly, since its
  tabs cannot be read. Which browsers can be asked is rechecked while KeyScribe runs, so a browser installed or
  updated later is used without relaunching. Asking goes through Apple Events, so macOS asks once per browser for Automation
  permission. The command waits for that answer, then reads the tabs; a prompt left unanswered for a
  minute counts as a browser that could not list its tabs. If the browser that would open the page has refused, the command fails with a pointer to
  that setting instead of opening a second copy. A place with no `browser` looks through the tabs of every
  running browser that can list them, and if none has the page open, opens it in whichever browser macOS
  opens that address with. If the tabs cannot be read in time, or the browser that would open the page could not list them, the command also fails
  rather than open a second copy of a page that may already be open. Once the command gives up, no further
  browser is asked, and a script already waiting stops on its own a few seconds later, so a browser that
  hangs holds up a later command for a few seconds at most. A place with a `browser` reads only that browser's tabs, and if that
  browser is not installed the command fails rather than opening another browser.
- **Focusing a tab re-checks it first**: the tab must still show the address it had when it was found
  (looked up again if it moved), compared case-sensitively like the match itself. If the tab is gone, the
  page is opened instead. If the browser does not answer in time, the command fails and nothing else is
  opened. An Apple Event already sent cannot be recalled, so a browser that answers late may still select
  the tab inside its own windows, but it is never brought forward: only an answer in time does that.
- **A take whose microphone stopped never runs a command**, including a loss that arrives while the command
  is being looked up or while a tab is being focused. Nothing further is opened or brought forward.
- `go back` returns to the window that was in front before the last switch by voice, even within the same
  app, or to its app when that window has closed or is no longer on this desktop. It never opens another
  copy of an app that has quit since, and an app that does not answer leaves the destination in place for
  another try. A command whose target was already in front keeps the earlier destination. Running a
  script or shortcut does not change it. It is kept in memory only, so it is lost when the app quits.
  Repeating `go back` switches back again.
- **Preview a command** in Settings never runs a command, script, or shortcut, but previewing a web place reads the open tabs,
  so it can be what first asks macOS for permission to control a browser, and previewing a phrase no app or
  place matches reads the open windows' and tabs' titles. Reading windows never asks for a permission; reading
  tabs can.

### Replacement matching & output

How a rule behaves once it matches:

- **Rules match the heard text once.** Replacement output is inserted as-is and is never scanned by
  another replacement. When matches overlap at the same position, the longest actual match wins. Equal
  matches prefer a mode rule over a Global rule, then the topmost rule in the same scope. Regex and
  literal rules use the same actual-match-length comparison; zero-length regex matches do nothing.
- **Literal rules match case-insensitively, on whole words** (`pipe` never fires inside `pipeline`);
  the replacement text is inserted verbatim (`$` / `\` are not template refs).
- **A literal rule matches only the words it names.** `pain` → `pane` leaves "pains" as said; a plural
  needs a rule of its own. When you add a one-word rule that writes a lowercase word, Settings offers that
  rule (`pains` → `panes`) as an unchecked option, saved as a separate rule (`ReplacementPlural`).
- **Regex rules also match case-insensitively by default.** The input is STT output, whose casing
  the engine chooses (it commonly capitalizes the first word), so a case-sensitive pattern would
  silently miss. Opt back into case sensitivity with an inline `(?-i)`. Capture substitution (`$1`,
  `\$` for a literal `$`) works as usual. Note the capture preserves the *matched* text's case — the
  replacement template has no case-folding, so `slash (\w+)` → `/$1` on a spoken "Dog" yields `/Dog`,
  not `/dog`.
- **A nested-quantifier ("evil") pattern is refused at authoring.** The pipeline screens patterns like
  `(a+)+` before running them (they can catastrophically backtrack; see `design.md` §4.2 table), so the
  editors reject such a pattern instead of saving a rule that would be silently dropped at dictation
  time. A hand-authored rule that fails the screen still loads but never runs; re-saving it requires
  simplifying the pattern.
- **Regex rules interpret `\n` / `\t` / `\r` in the replacement as real newline / tab / carriage
  return** — the same convention as an editor's regex-mode replace field (VS Code, Sublime). A
  literal rule does *not* interpret them; write `\\` for a literal backslash. **Spell the escape with a
  TOML literal (single-quoted) string** so the backslash reaches the rule intact — this is also how the
  Settings editor writes it:

  ```toml
  [[rules]]
  heard = 'insert code fence'
  replace = '```\n'      # regex mode: inserts a fenced line + a newline
  regex = true
  ```

  Dictate it alone and it comes out **bare** (see below), so the trailing newline is not trimmed. A
  *basic* (double-quoted) string is a TOML footgun here: TOML itself decodes `"...\n"` to a newline
  before any rule runs, so `"```\n"` would insert a newline even on a *literal* rule — use `'...\n'`
  (or `"...\\n"`) to keep the `regex` flag in control. Note a control char is inserted as-is only on
  the whole-utterance (bare) path; used mid-sentence it flows through the AI rewrite like any text.

- **A replacement that owns the WHOLE utterance is inserted exactly — bare.** When the entire
  dictation (ignoring surrounding whitespace and a trailing `.` / `!` / `?`) reduces to a single
  replacement, its generated value is inserted verbatim: **no AI rewrite, no `trailing` suffix, no
  `trim_trailing_punctuation`**. Said as *part of* a longer utterance, the same rule is ordinary text
  and the mode's normal rewrite/trailing apply. This makes spoken commands deterministic without a
  per-rule flag:

  | You say | with rule `slash (\w+)` → `/$1` | Output |
  |---|---|---|
  | "slash resume" | owns the whole utterance → **bare** | `/resume` |
  | "send slash resume" | part of a larger utterance → normal | `send /resume. ` |
  | "slash resume now" | part of a larger utterance → normal | `/resume now. ` |

  The trailing `. ` in the last two rows is the mode's normal decoration (rewrite punctuation +
  `trailing`); only the first row, where the command *is* the whole utterance, comes out bare. The
  rule is "one replacement owned the whole thing," so it never fires for a fuzzy-dictionary
  correction — only an explicit replacement that consumed the entire utterance.

  Only the rule's own text is frozen. Words a regex rule **captured** and placed with `$1` are still
  dictation, so numbers and the dictionary reach them: with `^(.*) end of transmission$` → `jasper $1` and
  `Metafield` in the dictionary, "fix the meta field errors, end of transmission" gives
  `jasper fix the Metafield errors`. A rule with no capture (`^p[ie]e?$` → `pi<CR>`) comes out exactly as
  written, and Return is still pressed only when one rule owns the whole utterance.

- **`whole_dictation = true` makes a rule a spoken command only.** The rule then acts only when it owns
  the whole utterance, as above, and leaves the same words in an ordinary sentence untouched. Without
  it (the default, and every rule written before the key existed), a rule acts anywhere it matches.
  Settings keeps the choice under **Advanced** (**Anywhere in a sentence** / **Only when said alone**), and a new rule whose replacement ends in `<CR>` starts as the latter:

  ```toml
  [[rules]]
  heard = 'slash resume'
  replace = '/resume<CR>'
  regex = true
  whole_dictation = true    # "send slash resume to Sam" is left as said
  ```

- **A regex rule matches inside words unless the pattern says otherwise.** `p[iy]e?` also changes
  "copy" and "pieces". The Settings editor checks a rule against a sample sentence and your recent
  History, flags matches inside other words, and offers **Match whole words**, which rewrites the
  pattern so neither end of a match can split a word. It writes the change into the pattern itself,
  so a hand-edited rule can use the same form:
  `(?:(?<!\w)|(?!\w))(?:p[iy]e?)(?:(?!\w)|(?<!\w))`.

- **A regex replacement can press Return with a terminal `<CR>`.** Appending `<CR>` to the *end* of a
  **regex** replacement template requests a physical **Return** key press after the whole-utterance
  insert — for a command like `slash resume` → `/resume` that then runs, sends, or activates a default
  control:

  ```toml
  [[rules]]
  heard = 'slash resume'
  replace = '/resume<CR>'   # inserts /resume, then presses Return
  regex = true
  ```

  - `<CR>` is stripped from the inserted text (with any whitespace right before it) — it never appears
    as literal text, and never reaches the AI rewrite. Capture expansion still works: `'/$1<CR>'`.
  - It is honored **only** when the rule owns the whole utterance (the bare path above). In the middle
    of a longer sentence the rule does its ordinary text replacement and presses nothing, unless
    `whole_dictation = true` keeps it out of sentences altogether.
  - It is recognized **only** in a regex rule and **only** at the very end. `<CR>` in a *literal* rule
    is inserted verbatim (Settings flags such a rule); a `<CR>` anywhere but the end of a regex template is invalid and the rule is
    ignored. Write `\<CR>` to emit the literal text `<CR>` in a regex replacement.
  - The Return is a real key press, **not** a guaranteed "send" — its effect depends on the focused
    target. It fires only after the text verifiably lands (never on a clipboard fallback, a password
    field, or if focus moved), and `replace = '<CR>'` alone presses nothing (empty output → no-speech).
  - **A trailing newline immediately before `<CR>` cannot be preserved.** All whitespace right before the
    marker — spaces, tabs, *and* line breaks — is stripped with it, so `last line\n<CR>` inserts `last
    line` and then presses Return. That is the intended shape for a submit-style macro; if you need a
    kept trailing newline, do not follow it with `<CR>`.

### Multiline replacement text & the authoring limit

A replacement may contain real line breaks, so a short spoken phrase can expand into a block of text
without regex syntax. The Settings **Use instead** field grows to a few lines and offers **Open in a
larger editor…** for a full multiline body. Quick-correction surfaces keep the compact field, while a
saved rule's edit popover shows the multiline editor inline.

- **The replacement is preserved exactly.** Only the heard phrase / regex pattern is trimmed; the
  replacement keeps its leading, trailing, embedded, and repeated whitespace and line breaks verbatim.
  An empty replacement adds a dictionary word in the composer; any nonempty value — including one made
  only of spaces or line breaks — is a replacement. (A saved rule may still replace with the empty
  string through the rule editor, the delete-text capability.)
- **Newline representation is not converted between forms.** A *literal* rule inserts exactly what you
  authored, so a real line break inserts a line break and the two characters `\n` stay the visible
  characters `\` and `n`. A *regex* rule interprets `\n`/`\t`/`\r` as controls (above), so a real line
  break and `\n` produce the same newline. The one normalization: pasted CRLF and lone CR are converted
  to LF at the editor boundary (macOS treats LF as the native break).
- **Authoring limit: 65,536 characters.** The editor shows `current / 65,536` and refuses to save an
  over-limit draft (the complete draft is retained so you can trim or copy it — never silently
  truncated). A hand-authored rule already over the limit still **loads** (the limit gates authoring,
  not loading); Settings surfaces it and requires shortening before that rule can be saved again. The
  compact list preview is always one bounded line regardless of the stored size.
- **A large macro's output is not scanned again.** Its content is inserted exactly as authored by the
  replacement stage, regardless of text that resembles another rule's heard phrase. An AI rewrite may
  still transform it unless the macro owns the whole utterance.
- **Replacement config is plaintext on disk.** Do not store credentials or other secrets in a
  replacement.

### `settings.toml` — general
```toml
schema_version = 1

load_on_login = false

[stt]
engine = "parakeet-ultra"       # the single active engine (default: Parakeet Ultra)
eviction = "fastest"            # "fastest" | "balanced" | "frugal" (default: fastest)
# Governs both STT-model residency AND idle microphone warm-up (the input unit is kept prewarmed for
# instant starts). Fastest = model loaded + mic held warm (periodic binding refresh); Balanced = both
# released after eviction_idle_seconds idle; Frugal = mic opened only while dictating, model freed each
# dictation. The natural voice that reads Coding agent replies follows the same tier: Fastest keeps it
# loaded, Balanced frees it after eviction_idle_seconds without use, Frugal frees it after each reply or preview.
# eviction_idle_seconds = 1800  # used when eviction = "balanced" (default: 1800 = 30 min)
# The one dictionary-mechanism control: recognition bias is default-ON for the engines that support it
# (the bias-capable ones) and can be disabled per engine. Post-STT dictionary recovery has no toggle
# — it runs whenever the mode's dictionary is non-empty. Only deviations are recorded (fresh install
# writes the list empty):
# recognition_bias_disabled_engines = []  # bias-capable engines with recognition bias turned OFF
# (The former dictionary_recovery_enabled_engines / dictionary_recovery_disabled_engines /
#  dictionary_recovery_engines keys are obsolete: ignored on read and dropped on the next write.)

[during_dictation]
other_audio = "quiet"           # what happens to other audio while you dictate or a reply update or answer is read aloud
                                #   speaks: "quiet" (default, turned
                                #   down but still audible), "mute" (silenced), "unchanged" (left alone).
                                #   Ducks (FaceTime-style, cannot strand); lands after the start sound,
                                #   instant when sounds = false
# (The former mute_system_audio key is obsolete: still read when other_audio is absent, and dropped on
#  the next write. true maps to "quiet" — deliberately NOT "mute": mute was the shipped default, so
#  upgrading users adopt the new default rather than keeping full silence. Pick "mute" to keep it.
#  false maps to "unchanged".)
keep_display_awake = true
sounds = true                   # start/end sounds
sound_volume = 100             # relative dictation-sound level; 100 = full cue level, 0 = silent (0 also
                                #   skips the start cue, so capture admits with no cue hold)

[history]
enabled = true
retention_days = 7              # default; delete day-files older than this

[hud]
appearance = "system"           # "system" | "opposite" | "light" | "dark"; the HUD only — every
                                #   window follows the Mac

[shortcuts]                                 # global shortcuts for menu-bar actions
add_vocabulary = "control+option+shift+v"        # canonical chord; "" = off
paste_last_dictation = ""                        # canonical chord; "" = off (default)

[insertion]                                 # how a paste hands the clipboard back; TOML-only, no Settings UI
# clipboard_restore_ms = 250                     # ms the dictation stays on the clipboard after the paste
                                                 #   keystroke, before your clipboard is put back (must be >= 1)

[audio]                                     # written by the Settings mic picker; no UI for the debug keys
# input_device_uid = "BuiltInMicrophoneDevice"   # preferred capture device; absent = follow the system default
# input_device_name = "MacBook Pro Microphone"   # possibly-stale label, so a disconnected device still reads as itself
# keep_captures = false                          # debug: retain a copy of each committed capture WAV
# keep_captures_max_mb = 500                     # soft budget for the archive; oldest pruned first

[coding_agents.spoken_result]               # Settings ▸ Modes ▸ Coding agent ▸ Replies
# enabled = true                                 # Reply updates; absent = false
# connection = "omlx"                            # id of the AI service that summarizes a finished reply
                                                 #   and describes a Pi prompt; absent or "" = None:
                                                 #   a longer reply is announced without a summary, and
                                                 #   notices still play as fixed sentences
# prompt = "…"                                   # the summary instruction; absent = the built-in default
                                                 #   (SpokenResultSettings.defaultPrompt)
# voice = "bf_emma"                              # speaker of the on-device voice, one of SpokenVoices.all;
                                                 #   absent or unknown = SpokenVoices.recommended
# text_only = true                               # Voice ▸ Off — text only: reply updates and Ask answers
                                                 #   are shown, never spoken; absent = false (spoken);
                                                 #   `voice` is kept
```

> **`[coding_agents.spoken_result]`** is read for replies only while the Coding agent feature is on. A reply of at most
> `SpokenResult.verbatimWordLimit` words (counted on the reply as written, so a reply that is mostly code is
> summarized rather than read as "code block") is spoken as it is, with markup removed, code blocks named and
> recognized secrets hidden, without any service call; a reply with nothing left to read, such as one that is
> only a table, is summarized instead; a longer one is sent to the chosen service, bounded to its opening and ending within
> `SpokenResult.inputCharacterLimit` characters and after best-effort redaction. With no `connection`, a reply that
> would be summarized is spoken as the conversation's name followed by "Replied. Open the conversation for the result."
> without any service call; a
> `connection` that names no saved service speaks it as unavailable. A redacted span is never
> restored into speech: the summary says "a hidden value" in its place. Every result starts with the name of
> the conversation that produced it, and a summary that fails, times out or comes back empty is spoken as that
> name followed by "No summary of the long reply. Open the conversation for the result." Unavailable summaries waiting
> together are spoken as one notice naming each conversation, followed by "No summaries of the long replies. Open the
> conversations for the results." The `prompt` alone sets a summary's length: it is requested once and read as returned,
> except that one over `SpokenResult.runawayWordLimit` words is cut short, with History keeping the full text. Turning `enabled` off keeps `connection`, `prompt` and
> `voice`, and so does `text_only`. `text_only` is an output choice, not a speaker: it changes only how an update or
> answer is delivered (shown on the panel instead of read aloud, with no voice loaded and no audio lowered), never which
> updates are given or in what order, and turning it off returns to the saved `voice`. It also applies to Ask modes
> (`output = "speak"`), which read `voice` and `text_only` from this table even while the Coding agent feature is off.
> Only turns the user's own dictation started, or that the user asked from inside the agent to hear, are spoken,
> and a conversation confirmed in front when its turn finishes is skipped without a service call unless the user asked
> to hear it. With `enabled` on, a dictated turn that starts waiting for
> approval or an answer, or whose connector stays gone mid-turn, is announced with a fixed notice whether or not
> `connection` is set; notices never call a service. Nothing is stored.

> **`[audio]`** — `input_device_uid` is a CoreAudio UID (stable across reconnect, unlike the ephemeral
> device id), resolved live at each bring-up: the preferred device if present, else the system default.
> Capture never changes the macOS system default input.
>
> `keep_captures` is a **debug affordance, default off, with no Settings UI** — a capture WAV normally
> lives only record→transcribe→delete. Turned on, each committed capture is cloned into
> `~/Library/Application Support/<KeyScribe|KeyScribeDev>-captures/` (a sibling of the config dir, so a
> WAV can never fire the config watcher) and the archive is pruned oldest-first to `keep_captures_max_mb`.
> The clone is COW, so retention writes no extra bytes — it only stops the WAV's blocks from being
> reclaimed. At the 16 kHz mono-float capture format, **100 MB ≈ 27 minutes** of speech.
>
> `keep_captures_max_mb` is a **soft budget, not a hard cap**: the newest capture is always retained even
> if it alone exceeds it, since deleting it would leave nothing to inspect — the one thing the archive
> exists for. So the archive can transiently hold one over-budget file.
>
> `KEYSCRIBE_KEEP_CAPTURE=<dir>` (or `--keep-capture <dir>`) overrides the directory, wins when both are
> set, and is **never pruned** — retention only ever deletes inside the app-owned archive. Both keys are
> omitted from the file while `keep_captures` is off, and **Erase All Data** removes the archive.

> `clipboard_restore_ms` is **global, not per-mode**: the delay depends on how the target app reads the
> pasteboard and how fast the machine is, neither of which varies by mode, so one value serves every mode
> (Plain Dictation included) and Paste Last. The window exists because a target may read the pasteboard
> **asynchronously, and possibly more than once** after ⌘V (reported of Chromium and Electron apps), so
> restoring instantly can hand that read your old clipboard instead of the dictation. It is also the
> window in which pressing ⌘V yourself pastes the dictation a **second** time instead of your clipboard,
> so it is kept as short as an asynchronous reader tolerates; raise it only for a target where the paste
> comes out empty or stale. A value below 1 is refused (the file fails to load). Elided from the file at
> the default. Ignored under a mode's `clipboard_sync = true` (which never restores) and
> `insertion = "type"` (which never touches the clipboard).

> **`[shortcuts]`** drive the standalone **Add to Vocabulary…** panel and
> the **Paste Last Dictation** action (both also always available in the menu bar). Add to Vocabulary
> **defaults on** to `⌃⌥⇧V` — the
> triple-modifier zone the system never reserves, so the global grab is least likely to collide with
> an app; **Paste Last Dictation defaults off** (`""`). An **absent** key falls back to that field's
> default; an explicit `""` means the user turned it
> off. Only **chord** descriptors are honored (a
> bare modifier key already drives dictation). The event tap is **active** (`.defaultTap`), so a
> registered chord — for these shortcuts and for mode triggers — is **swallowed** before the focused
> app sees it (otherwise e.g. ⌃⌥E reaches the app as the Option-E dead key and replaces the selection).
> The tap falls back to listen-only when an active tap can't be created (Accessibility not yet granted),
> in which case the chord passes through until Accessibility is granted. Set in Settings ▸ General.

---

## Conventions
- **Older schema versions** are normalized on read. KeyScribe does not rewrite a file just because a
  read migration ran, and it does not create pre-migration backups today; a later save writes the
  current schema.
- **Rewrites normalize to this schema** and drop comments. A file whose `schema_version` exceeds the
  app's is left untouched and surfaced (`design.md` §5.1). **No rewrite drops an unknown key:** a save
  from the app to a file holding one is refused with a notice naming the file and key, leaving the file
  and the unsaved edit as they were, and an automatic rewrite (a starter-mode update or rename) skips
  that file. For `settings.toml`, app-wide changes still apply but are not saved until the key is fixed
  or removed. A configuration reload keeps those unsaved changes while what `settings.toml` sets is unchanged,
  and saves them once the key is gone; when the file sets something else, its contents replace them and the
  HUD says so, after the result of a dictation in progress.
- **Unknown keys are reported, not fatal.** A key this schema does not read — usually a typo such as
  `trigger_key` for `trigger_keys` — loads as if absent and is listed in Settings → Maintenance (and in the
  mode's editor for a mode file), with the nearest real key when one is close. Retired keys noted in this
  document are exempt.
- **Secrets never in TOML** — saved LLM keys live in Keychain; command-generated tokens live only in
  memory. TOML stores `key_ref`, `auth_method`, and the command to run, never key or token material.
- **kebab-case ids**, snake_case fields, consistently.

## Notes & conventions
- **Verbatim is a live edit** — gated by `commands.live_edits` (no separate toggle); triggered
  by "begin verbatim" / "end verbatim".
- **"Insert clipboard contents" is a live edit** — same `commands.live_edits` gate; triggered by
  "insert clipboard contents"; pastes the
  clipboard at that point, tokenized like a verbatim span so it is inserted as-is and never sent to
  the LLM. Dictation only (not edit-in-place). Empty/absent clipboard leaves the phrase as text.
  "insert clipboard as code" (`ClipboardTokenizer.codePhrases`) inserts the same value inside a Markdown
  fence on lines of its own, with a fence longer than any backtick run in the clipboard.
  In the Coding agent mode (`AgentClipboard`), copied files are inserted as their paths, and an image
  (saved as PNG) or a PDF is written to a `clipboard-for-agents` folder in the temporary directory, kept
  for a day (pruned at launch, hourly, and on each save), and inserted as its path; neither form is
  fenced. A connector that announces the `images` feature also receives each saved image's path in the
  `submit` command's `images`, and attaches the image to the message.
- **`include_global` is per-set** — dictionary and replacements each carry their own flag.
- **Key descriptor format** — lowercase tokens joined by `+`, and the token list decides the shape:
  **every token a modifier and no base key → a modifier-only trigger** (the set is held with no key
  at all); **a base key present → a chord**; a lone `mouseN` → a mouse button.
  - **Modifiers** are `control` `option` `shift` `command` `fn` (aliases `ctrl`/`alt`/`cmd`/`globe`),
    each optionally prefixed `left_` or `right_` to name the physical key: `left_command`,
    `right_option`, `left_ctrl`. `fn` is never sided — there is only one of it.
  - **A modifier-only trigger** is 1–4 modifiers, at most one of each, and never both sides of the
    same one (`left_command+right_command` is rejected). `hyper` is a **parse alias** for
    `control+option+shift+command` — it keeps loading and stays spelled `hyper` on disk, since the
    stored string is round-tripped verbatim. It is rewritten to the long form only when that mode's
    shortcut is set again, by recording it or by picking ⌃⌥⇧⌘ from the well's menu. Sideless means
    either key (`command` matches both ⌘s); sided means that one, and requires the other to be up.
    Examples: `"fn"`, `"right_option"`, `"left_command"`, `"left_command+left_control"`,
    `"command+control"`, `"fn+left_command"`.
  - **A chord** is the four chord modifiers plus one base key. Sides and `fn` are **rejected inside a
    chord** — `RegisterEventHotKey` cannot distinguish left from right and carries no Fn, so
    `left_command+k` and `fn+k` are errors rather than a silently widened binding.
    Examples: `"control+option+a"`, `` "control+`" ``, `"option+space"`, `"command+up"`, `"f5"`.
  - **A mouse button** is `mouseN` where `N` is the macOS button number ≥ 2 (`mouse2` = middle,
    `mouse3`/`mouse4` = the back/forward thumb buttons; left = 0 and right = 1 are rejected so a
    trigger can never hijack a normal click). A bound mouse button is **consumed globally** while
    KeyScribe runs — it no longer performs its normal action (e.g. browser back) — which is the same
    trade other dictation apps (Wispr, Superwhisper) make. Mouse buttons are observed under
    Accessibility alone (no Input Monitoring), like the modifier triggers.
  - **Two modifier-only triggers overlap when one press engages both** — same modifiers, and no
    shared modifier where the two name opposite keys. `command` and `right_command` are the same
    press (the later one is suppressed, as with any duplicate shortcut); `left_command` and
    `right_command` are two usable triggers, because a sided trigger requires the opposite key to be
    up.
  - **A strict subset is warned about, not suppressed.** `left_command` under
    `left_command+left_control` is pressed on the way into it, and the Settings well says so. At
    runtime the 150 ms chord grace holds the smaller trigger's arm back, so pressing the pair as one
    motion starts only the pair. The larger trigger is warned too, as is a key chord whose modifiers
    include another mode's modifier-only trigger (`option+/` beside `right_option`): held longer than the
    grace before the key, the modifier-only mode starts and is then cancelled by the key.
  - **The recorder writes the keys that were actually pressed**, sides and all: recording Left-⌘ + Left-⌃
    stores `left_command+left_control` and binds those keys. A trigger recorded on one side therefore does
    not fire on the other — recording ⌃⌥⇧⌘ on the left stores the all-left set, and reaching for the right
    ⇧ will not fire it. Write the sideless form here for a trigger that should accept either key.
  - **Recommended default for new modes: `fn`/Globe with `hold-or-tap`** (most familiar — Wispr and
    Apple both center on it), with **`right_option`** offered as the conflict-free alternative
    (Apple Dictation also double-taps Fn).
- **A base key is a character, not a position** — and that is what makes the descriptor portable.
  A **printing** key is written as the character the key means **as a shortcut**: `a`, `7`,
  `` ` ``, `[`, `/`, and any non-ASCII key a layout actually has (`é` on AZERTY). It is resolved
  through the **active keyboard layout** each time triggers are registered, using the same rule
  macOS itself uses — the layout's **Command-modifier table**, falling back to the plain key when a
  layout has none. That matters in both directions: on a non-Latin layout (Russian, Greek, Hebrew,
  Thai) no Latin letter is reachable by typing at all, and the Command table is what puts `⌘V` on
  the physical V key; under **Dvorak** a chord follows the Dvorak positions, while under
  **Dvorak — QWERTY ⌘** it follows the QWERTY ones, which is that layout's entire purpose for a ⌘
  shortcut — note that a chord *without* ⌘ (`control+option+e`) lands on the QWERTY position there
  too, where that layout would otherwise keep you on Dvorak. Two
  consequences: a chord the current layout cannot mean anywhere is **not registered at all** (the
  Settings shortcut well says *Not on your current keyboard layout*), and switching input source
  **re-registers** every chord without a relaunch. Because the base key is a key's *plain*
  production, a character that needs Shift is not a base key — write `` control+shift+` ``, never
  `control+~`. The same rule makes a character that a *given layout* only reaches with Shift
  off-layout there: `+` and `*` on US, and every digit on AZERTY, where the row types `&é"'(§è!çà`
  unshifted. Name the key's unshifted character instead (`control+(` is the AZERTY spelling of the
  key labelled 5) or record the shortcut and let the recorder store the right one. The numeric
  keypad is never a substitute: it has its own names, so `control+5` and `control+keypad_5` always
  mean different keys.
  The one exception is `+` itself, which is written `plus` (`control+plus`) because the grammar
  splits on `+`. It stays a word in the file too, since the character cannot survive a round trip.
- **A non-printing key is written by name**, since its position is fixed by the hardware and never
  moves with the layout: `f1`…`f20`, `space`, `tab`, `return`, `delete`, `forward_delete`, `escape`,
  `home`, `end`, `page_up`, `page_down`, `up`, `down`, `left`, `right`, and the keypad
  (`keypad_0`…`keypad_9`, `keypad_decimal`, `keypad_plus`, `keypad_minus`, `keypad_multiply`,
  `keypad_divide`, `keypad_equals`, `keypad_enter`, `keypad_clear`). **The function row is the only
  key that may be bound bare** — every other key needs at least one modifier, so a trigger can never
  swallow ordinary typing or navigation. `escape` chords are **TOML-only**: Escape cancels the
  Settings shortcut recorder, so it cannot be captured there.
- **Per-mode language** — out of scope; no `language` field, and no global language setting either.
  Transcription language follows the active engine (`design.md` §4.1), and the **rewrite** writes in
  whatever language `<content>` is already in (`prompt_design.md`). A mode that must pin a language
  or translate says so in its own `ai_rewrite.prompt`, which the language rule explicitly defers to —
  that instruction *is* the per-mode override, so a structured field would only duplicate it.
