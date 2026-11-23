import assert from "node:assert/strict"
import { test } from "node:test"
import { spawnSync } from "node:child_process"
import { chooseTerminal, escaped, outside } from "./lib/terminal.ts"

test("the run uses the terminal it is told to, and otherwise Ghostty when it is installed, then Terminal", () => {
  assert.equal(chooseTerminal({ AGENT_TERMINAL: "terminal" }, () => true), "terminal")
  assert.equal(chooseTerminal({ AGENT_TERMINAL: "ghostty" }, () => false), "ghostty")
  assert.equal(chooseTerminal({}, (path) => path === "/Applications/Ghostty.app"), "ghostty")
  assert.equal(chooseTerminal({ GHOSTTY_APP: "/Apps/Ghostty.app" }, (path) => path === "/Apps/Ghostty.app"), "ghostty")
  assert.equal(chooseTerminal({}, () => false), "terminal")
  assert.throws(() => chooseTerminal({ AGENT_TERMINAL: "iterm" }, () => true), /takes ghostty or terminal/)
})

test("a window the run opens leaves the multiplexer it was started from, so attaching to the agent is not refused as nested", () => {
  assert.deepEqual(outside({ TMUX: "/tmp/t,1,0", TMUX_PANE: "%1", HERDR_ENV: "1", HERDR_SOCKET_PATH: "/x", PATH: "/bin" }),
    "unset HERDR_ENV HERDR_SOCKET_PATH TMUX TMUX_PANE; ")
  assert.equal(outside({ PATH: "/bin" }), "")
})

test("a window title is matched literally when the run looks for its own window's process", () => {
  const title = "ks (claude) kestrel 1.2 #3 [x]"
  const pattern = `--title=${escaped(title)}( |$)`
  const match = (line: string) => spawnSync("/bin/sh", ["-c", `printf '%s\\n' "$1" | /usr/bin/grep -E -- "$0"`, pattern, line]).status === 0
  assert.ok(match(`ghostty --title=${title} -e /bin/sh`))
  assert.ok(!match("ghostty --title=ks Xclaude) kestrel 1a2 #3 x -e /bin/sh"))
  assert.ok(!match(`ghostty --title=${title}0 -e /bin/sh`))
})
