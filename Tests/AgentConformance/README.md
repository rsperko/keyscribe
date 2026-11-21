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
| Claude Code | `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY`, since a new configuration folder has no login | `CLAUDE_MODEL` (default `haiku`), `CLAUDE_BIN` |
| Pi | `auth.json` and `models.json` copied from `~/.pi/agent` (or `PI_LOGIN_HOME`), plus your default model | `PI_MODEL`, `PI_BIN` |
| omp | `config.yml`, `models.yml` and a backup of `agent.db` from `~/.omp/agent` (or `PI_LOGIN_HOME`) | `OMP_BIN` |
| Codex | `auth.json` copied from `~/.codex` (or `CODEX_AUTH_HOME`) | `CODEX_MODEL`, `CODEX_BIN` |
| bb | a second copy of `bb.app` started on a scratch data folder and its own port; its threads use bb's provider logins | `BB_APP` |
| Ultimate | your Pi login, which Ultimate shares | `ULTIMATE_MODEL`, `ULTIMATE_BIN` |

A terminal agent runs in a private tmux server, and the driver answers the screens a fresh setup shows (trust this
folder, review hooks, an update notice) the way a person would.

## Ultimate page conformance

`make test-ultimate-page` exercises Ultimate in a real Chrome app window, using a real branch made by
the standing agent's branch tool, an owned subagent, the standing agent, an ordinary conversation and a side chat. Set
`ULTIMATE_CLONE` to an installed checkout, `ULTIMATE_BIN` to its command and `ULTIMATE_NODE` to its
supported Node executable. `ULTIMATE_MODEL` selects the model. The run needs another app window for
the background-reply checks, moves foreground focus, preserves the clipboard, and writes each case's
result to `conformance.json` in its temporary instance folder. A failed run keeps its scratch folders.

## Adding an agent

Write a driver in `lib/` that implements `AgentDriver` (`lib/driver.ts`): set up a scratch folder, start the agent the
way people normally start it, name its conversation, report when it is idle, and read its messages from the agent's
own record. Register it in `run.ts`. Every exercise then runs against it; an exercise for something the agent cannot
do should check that the user is told so, not be skipped.

## Adding an exercise

Add it to `exercises.ts` with an id from its family (D delivery, I images, R replies, N names,
P discovery, C connection, L install, S safety). Assert what the agent recorded. An exercise for something only some
agents' conversations have, such as an address of their own in their app (a driver's `addresses`), sets `applies`
and reports N/A for the others; anything a user could ask of every agent still runs against every agent.
