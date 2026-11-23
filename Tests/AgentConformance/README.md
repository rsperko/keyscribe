# Agent conformance

Exercises that run the real KeyScribe app against a real agent, so a change to the agent bridge, or a new version of
an agent, is checked the way a user would meet it. Connector tests check each side against a stand-in; these check
both sides together.

## Supervised verification

```sh
make verify-agents-preflight                  # check tools, logins, Metal toolchain and env without running tests
make verify-agents-unit                       # all Swift and connector suites, no live agents
make verify-agents CHECKS=bb-plugin,swift      # selected checks, never a full-gate receipt
make verify-agents                            # complete gate, including real agents and Ultimate's native window
make verify-agents FORCE=1                    # fresh complete gate, including deterministic checks
make check-diff                               # check diff for stray comments, AI attributions and leaked scratch dirs
python3 -B scripts/verify_agents.py --list     # check IDs and exact commands
```

The complete gate builds an isolated app under `.verification/artifacts/`, runs each registered live driver,
and runs Ultimate's headless and native-window checks. It needs the logins and tools listed below
and Ultimate's environment variables. Set `KEYSCRIBE_SCREEN_NOTICE_CMD` if you use a screen-takeover
notice script (`<cmd> on "<reason>" <minutes>` / `<cmd> off`). It moves foreground focus and uses the agents'
models. Missing prerequisites fail the required check; they do not produce a passing gate.

The test instance must see key presses and clicks to confirm the conversation in front. macOS charges a test
instance's Accessibility to the app the run was started from (your terminal, or the agent whose shell started it), not
to the build the run uses, so start the run from a terminal that has Accessibility. It only listens and never takes
your input. A run whose instance cannot see input stops before its first exercise and names the app it was started
from, rather than failing every exercise that speaks to the conversation in front.

Terminal agents and the window the run looks away to open in Ghostty when it is installed (`GHOSTTY_APP`), otherwise
in Terminal; `AGENT_TERMINAL=ghostty` or `terminal` chooses. A Ghostty window is a separate copy of Ghostty without
your configuration or saved windows, and leaves the tmux or herdr the run was started from, so attaching to the
agent is not refused as nested. Terminal needs Automation for the app the run was started from; the run checks it can
drive the chosen terminal before the first exercise and names what to allow.

A run also stops before its first exercise while VoiceOver is on. The instance shows each reply as text, and under
VoiceOver a reply panel stays open until someone closes it, so the next reply would wait behind it and the exercise
judging that reply would fail. Keep the pointer off the reply panel during a run for the same reason.

A test instance (one started with `--no-input`) records, for each request a take sent, whether its reply was read or
why not, and each time it has nothing left to read (`scripted-reads.jsonl` in its support folder, request ids and
reasons only). The exercises count reads by request rather than by what a reply said, and look a take's History entry
up by the id its result names rather than by its words or its time. An exercise judges a reply once the instance has
gone quiet after it and stayed quiet for `settleSeconds` (1 s by default). Waiting for quiet covers a reply still
being summarized or spoken, however long that takes; the extra second covers only a second turn-end event that the
connector sends with the first one and that arrives just after the first was handled.

A run leaves your own setup as it found it. It records the agents' configuration files in your home folder (the list
is `watchedInHome` in `lib/home-audit.ts`) before it starts and fails afterwards, naming each file it changed, added
or removed. Conversation logs and histories are not compared, since you may be using your agents meanwhile; a linked
extension is compared by where its link points, and `.git` and `node_modules` folders by their presence only.

The runner limits concurrent jobs (`JOBS=2` by default), serializes SwiftPM/build work and screen use,
and reports progress without another process polling its logs. It refuses a second verification run in
the same checkout or a Swift build already active there. A silence deadline captures process diagnostics
and stops that job; an absolute deadline bounds work even while it keeps printing. Only processes in the
job's own process group are signalled. Live harnesses handle termination by cleaning up their own instances.

Every run writes `.verification/runs/<run>/receipt.json`. It records the selected and required checks,
source-content digest, tool versions, commands, result and log paths. Partial runs never set `full_gate`.
The runner narrows only by `CHECKS`: it drops the harnesses' own filters (`ONLY`, `TARGETS`, `REPEAT`, `FAIL_FAST`)
from every check's environment, so a run that passes covered every case.
Changes during a run invalidate its result. Unchanged deterministic checks may reuse their recorded pass
only with matching source contents, environment, tool versions and command; a build also requires matching
app contents. Live checks always run again. Use `FORCE=1` for a fresh final gate after review.

Failures retain a local bundle beside their result: the error and log tail, process diagnostics (sampling active hung descendants rather than a wrapper parent, plus structured Swift Testing failure/hang/slow triage), and,
for live conformance, the test instance's recent History, discovery report, driver diagnostics (tmux screen, bb runtime, or Ultimate log and metadata-only bridge trace) and agent's own history. Native
Ultimate failures also record window and visible-editor facts. Bundles copy no login files and are never
uploaded. A generic failed run keeps the app instance's diagnostic folder; retaining the agent's scratch
setup and copied login still requires `KEEP=1`. A failed native Ultimate run keeps its scratch setup as before.
A folder kept on purpose carries a marker file, so `make check-diff` reports only folders a run failed to clean up.

`REPEAT=N` runs each exercise again against the same conversation, so an exercise counts only the messages its
own round added.

Focus/connection races also run through one shared contract in the bb and Ultimate connector suites.
`lib/event-orders.ts` generates every interleaving while preserving each event source's own order; an
oversized grid fails instead of silently checking a subset. Add a discovered ordering to these deterministic
contracts before relying on another live run to encounter it.

```sh
make build
make test-agents AGENT=codex                                    # every exercise
make test-agents AGENT=codex ONLY=D1,R1 FAIL_FAST=1 REPEAT=3    # narrow flake reproduction
make test-agents AGENT=codex KEEP=1                             # keep the scratch folders to look at afterwards
make test-ultimate-page ONLY="first-run|Tab" TARGETS=main FAIL_FAST=1 REPEAT=5
```

`AGENT=all` runs every agent that has a driver, one after another, and ends with a line per agent.
`run.ts --agent` with no value lists them. To run against another build of the app, such as
a downstream one, point `KEYSCRIBE_APP` at its executable inside the `.app` bundle.

## What a run does

1. Checks that the dev build knows every flag the run uses, and stops if it does not. An older build would ignore
   `--config-dir` and `--no-input` and start a second app on your real bridge.
2. Starts a second KeyScribeDev with its own support folder under `/tmp` and `--no-input`, so it never takes your
   hotkeys or mouse buttons and only reaches the agent setups enrolled in that folder. Its passive input monitor
   still detects focus changes during a take. Your own KeyScribeDev keeps
   running.
3. Gives the agent a scratch configuration folder, a scratch project, and a private tmux server. The agent's login is
   copied into the scratch folder and deleted with it.
4. Installs the connector into that folder with `--connector install`, the way Settings does.
5. Runs each exercise with `--agent-take --json --wait-reply`, then checks the outcome against the agent's own record
   of the conversation, never against KeyScribe's receipt alone. A reply is compared by SHA-256: its text never
   leaves the app.
6. Uninstalls the connector, checks the agent's own settings survived, and deletes the scratch folders.

Each run spends a little of the agent's model on short replies. Set the agent's model through its driver's variable
(for Codex, `CODEX_MODEL`).

## What each agent needs

Every driver finds the agent's command through your login shell, or through the variable named below. Each starts the
agent in a scratch project folder called `kestrel`, which is the name the exercises address it by.

| Agent | Login it uses | Choose the model or command |
|---|---|---|
| Claude Code | `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY`, or the `apiKeyHelper` and `env` of `~/.claude/settings.json` (or `CLAUDE_LOGIN_HOME`), since a new configuration folder has no login | `CLAUDE_MODEL` (default `haiku`), `CLAUDE_BIN` |
| Pi | `auth.json` and `models.json` copied from `~/.pi/agent` (or `PI_LOGIN_HOME`), plus your default model | `PI_MODEL`, `PI_BIN` |
| omp | `config.yml`, `models.yml` and a backup of `agent.db` from `~/.omp/agent` (or `OMP_LOGIN_HOME`) | `OMP_BIN`, `SQLITE_BIN` |
| Codex | `auth.json` copied from `~/.codex` (or `CODEX_AUTH_HOME`), and the provider its `config.toml` chooses (`model_provider` and that provider's table, read with Python 3.11 or later, `PYTHON_BIN`), so a provider with its own auth command works without `auth.json`. KeyScribe reaches Codex only through its shared app server, so a Codex that starts none fails setup saying so | `CODEX_MODEL`, `CODEX_BIN` |
| bb | a second copy of `bb.app` (`BB_APP`), cloned into the scratch folder so it runs from a location of its own as a separate copy of bb does, and started on a scratch data folder, its own ports and its own Electron profile (bb runs one copy per profile, so without one it quits at once beside yours). The driver marks bb's first-run setup guide done, as for a scratch Ultimate home, since the guide covers the window. The run stops it with SIGKILL, never a quit, and keeps killing every process whose arguments or environment name its scratch folder until none is left, because a packaged bb installs a downloaded update into its app when it quits, and that app is yours; its threads run on Codex with a copy of your Codex login (`CODEX_AUTH_HOME`) in a scratch `CODEX_HOME`, and its Pi folder is scratch too, so nothing the scratch copy runs is recorded in your own Codex or omp history | `BB_MODEL` (default `gpt-6-luna`), `BB_APP` |
| Ultimate | your Pi login, which Ultimate shares | `ULTIMATE_MODEL`, `ULTIMATE_BIN` |

A terminal agent runs in a private tmux server (`TMUX_BIN` names tmux), started without your `~/.tmux.conf`, and the
driver answers the screens a fresh setup shows (trust this folder, review hooks, an update notice) the way a person
would. A screen it does not know fails setup with that screen in the failure bundle. If the agent drops the first
Return while it loads, the driver presses Return again while the words are still in its prompt.

A driver offers `window` when its conversation can be put in a window of its own: show it there, report whether a
focused window shows it and what its message box holds, and add text to that box. bb's is its app window; a terminal
agent's is a terminal window attached to its private tmux server, opened with a title unique to each time it is shown,
with the draft read from the line the cursor is on. A Terminal window is found by that title and brought forward
through Terminal's own scripting (`focus`, since Terminal's windows reach the test instance without their titles); a
Ghostty window is found by its own process and brought forward by the test instance. Stopping a terminal agent waits for its
processes to exit before its scratch folder is removed, so nothing it writes on the way out is left behind; one that
ignores the hangup is killed, and one still running after that fails the run and keeps its scratch folder. Ultimate's is a Chrome app window on a scratch profile
(`CHROME_BIN`), read and filled through Chrome's debugging port. The exercises for the conversation in front, open,
go to and draft joining run only against such a driver, move focus between its window and an idle window the run
opens for this, never another app's window (bringing a chat app forward can mark its messages read), and never type
into a window: a draft goes in through tmux or the app's own API. Only a
window its app can open again on its own (`reopens`, bb) runs the exercise for opening with no window open. A window
also declares what its agent does with a take named to it while it is behind and its box holds a draft
(`takeBehindDraft`): keeps it, saying so, or sends it alone; and what it does with a take while it is in front and
its box holds a draft (`takeInFrontOfDraft`): sends the two joined, or sends the take alone and leaves the draft
(Codex, whose box KeyScribe can only send to, not add to). D10 fails when the agent does the other. A driver
declares what its agent does with a take sent while it works (`busyTake`): it joins the running turn (the default),
or it waits for that turn to end and the app says it is queued (Claude Code, which offers a plugin no way to add the
user's own words to a running turn). D2 checks the declared one, and that the agent's last answer follows the take. A window
that can open a second page of its app in a browser driven by automation offers `openAutomated`, once for each signal
the connector reads (`automatedKinds`): Ultimate's is a headless Chrome on a scratch profile showing another
conversation in a tab detached from Ultimate's shared view, so opening it never changes what the page on screen shows
(it fails if it does), held through one debugging connection that turns on focus emulation before the page loads (Chrome drops
it when the connection closes), with only one signal present: `webdriver` (`--enable-automation` and a visible
browser's user agent) or `headless` (automation detection turned off, the headless user agent). It fails before the exercise unless
that page claims focus and its report reaches the connector, read from the bridge trace; a trace at its record limit
without that report fails with that reason. D15 then checks, for each, that a take with no name still goes to
the conversation in front and is not read over it, and that a reply behind is still read while the page is open.
Stopping Ultimate closes its Chrome browsers and its server and fails, keeping the scratch folder, if any of them fails. bb's driver installs a test-only plugin,
`bb-window/`, into its scratch copy of bb for this: `bb thread open` shows the thread, and the plugin answers through
`bb plugin rpc call` from inside bb's own window, using bb's composer API to fill the box. It is never installed
anywhere else. A driver whose agent's app can add its own note to a running turn (bb's notice that a child thread
finished) offers `noteFromHost`, which R7 uses. One whose app can be
made unreachable offers `server` to stop and start it (bb: its server is killed, then the scratch copy is started
again on the same folder and ports; Ultimate: its server is stopped and started again on the same port and
project). One whose running turn the user can stop offers `interrupt` (a terminal agent: Escape). bb's scratch threads run on a small model at a low reasoning level, since every exercise asks
for one short reply.

Exercises that copy something set the clipboard through the context (`clipboard.set`) inside `clipboard.keep`, which
saves your clipboard first and restores it afterwards, through `clipboard.swift`. The `mark` it hands the exercise
records the clipboard at that moment and checks later that a take put it back exactly; its copy is removed with the
saved one, even when the exercise fails.

## Ultimate page conformance

`make test-ultimate-page` exercises Ultimate in a real Chrome app window, using a real branch made by
the standing agent's branch tool, an owned subagent, the standing agent, an ordinary conversation and a side chat. Set
`ULTIMATE_CLONE` to an installed checkout, `ULTIMATE_BIN` to its command and `ULTIMATE_NODE` to its
supported Node executable. `ULTIMATE_MODEL` selects the model. It looks away to an idle window it opens itself for
the background-reply checks, moves foreground focus, preserves the clipboard, and writes each case's
result to `conformance.json` in its temporary instance folder. A failed run keeps its scratch folders.

## Adding an agent

Write a driver in `lib/` that implements `AgentDriver` (`lib/driver.ts`): set up a scratch folder, start the agent the
way people normally start it, name its conversation, report when it is idle, and read its messages from the agent's
own record, including where the agent's record says each turn ended (an `ended` message), never inferred from
what a reply says. Register it in `run.ts`. Every exercise then runs against it; an exercise for something the agent cannot
do should check that the user is told so, not be skipped.

## Adding an exercise

Add it to `exercises.ts` with an id from its family (D delivery, I images, R replies, N names,
P discovery, C connection, L install, S safety). Assert what the agent recorded. An exercise for something only some
agents' conversations have, such as an address of their own in their app (a driver's `addresses`), sets `applies`
and reports N/A for the others; anything a user could ask of every agent still runs against every agent. An exercise
that needs a driver capability (`window`, `noteFromHost`, `server`, `interrupt`) sets `applies` the same way, and `exercises.test.ts` gives
its fake agent every capability, so each exercise's own logic is checked without an agent.
