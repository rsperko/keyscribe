import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { Tmux } from "./lib/tmux.ts"
import { until } from "./lib/util.ts"

test("stopping waits for the agent's processes to finish writing on their way out, so nothing lands after the scratch folder is removed", async () => {
  const folder = mkdtempSync(join(tmpdir(), "ks-tmux-"))
  const tmux = new Tmux(`ks-tmux-test-${process.pid}`)
  try {
    const late = join(folder, "written-on-exit")
    const ready = join(folder, "ready")
    tmux.start(folder, `sh -c 'trap "sleep 1; touch ${late}; exit 0" HUP TERM; touch ${ready}; while true; do sleep 0.1; done'`)
    await until("the agent ready to write on its way out", () => (existsSync(ready) ? true : undefined), 10, 100)
    await tmux.stop()
    assert.ok(existsSync(late), "stop returned before the agent finished exiting")
  } finally {
    tmux.kill()
    rmSync(folder, { recursive: true, force: true })
  }
})

test("stopping ends an agent that ignores hangup and terminate before it returns, so the scratch folder is never removed under it", async () => {
  const folder = mkdtempSync(join(tmpdir(), "ks-tmux-"))
  const tmux = new Tmux(`ks-tmux-stubborn-${process.pid}`)
  try {
    const pid = join(folder, "pid")
    tmux.start(folder, `sh -c 'trap "" HUP TERM; echo $$ > ${pid}; while true; do sleep 0.1; done'`)
    await until("the agent's pid", () => (existsSync(pid) && readFileSync(pid, "utf8").trim()) || undefined, 10, 100)
    const agent = Number(readFileSync(pid, "utf8"))
    await tmux.stop(1_000)
    assert.throws(() => process.kill(agent, 0), { code: "ESRCH" }, "stop returned with the agent still running")
  } finally {
    tmux.kill()
    rmSync(folder, { recursive: true, force: true })
  }
})
