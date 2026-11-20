# Agent conformance

Exercises that run the real KeyScribe app against a real agent, so a change to the agent bridge, or a new version of
an agent, is checked the way a user would meet it. Connector tests check each side against a stand-in; these check
both sides together.

```sh
make build
make test-agents AGENT=codex            # every exercise
make test-agents AGENT=codex ONLY=D1,R1 # some of them
make test-agents AGENT=codex KEEP=1     # keep the scratch folders to look at afterwards
```

`AGENT=all` runs every agent that has a driver, one after another, and ends with a line per agent.
`run.ts --agent` with no value lists them. To run against another build of the app, such as
a downstream one, point `KEYSCRIBE_APP` at its executable inside the `.app` bundle.

## What a run does

1. Checks that the dev build knows every flag the run uses, and stops if it does not. An older build would ignore
   `--config-dir` and `--no-input` and start a second app on your real bridge.
2. Starts a second KeyScribeDev with its own support folder under `/tmp` and `--no-input`, so it never takes your
   hotkeys or mouse buttons and only reaches the agent setups enrolled in that folder. Your own KeyScribeDev keeps
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

## Adding an agent

Write a driver in `lib/` that implements `AgentDriver` (`lib/driver.ts`): set up a scratch folder, start the agent the
way people normally start it, name its conversation, report when it is idle, and read its messages from the agent's
own record. Register it in `run.ts`. Every exercise then runs against it; an exercise for something the agent cannot
do should check that the user is told so, not be skipped.

## Adding an exercise

Add it to `exercises.ts` with an id from its family (D delivery, I images, R replies, N names,
P discovery, C connection, L install, S safety). Assert what the agent recorded.
