import assert from "node:assert/strict"
import { test } from "node:test"
import { run, shutDown, stopEach } from "./lib/util.ts"

test("every step of stopping an agent runs even when an earlier one fails, and each failure is reported", async () => {
  const ran: string[] = []
  await assert.rejects(stopEach(
    async () => { ran.push("tmux"); throw new Error("a pane kept running") },
    async () => { ran.push("server"); throw new Error("the server kept running") },
    async () => { ran.push("last") },
  ), /a pane kept running; the server kept running/)
  assert.deepEqual(ran, ["tmux", "server", "last"])
})

for (const [preserve, stops, kept] of [[false, true, false], [true, true, true], [false, false, true], [true, false, true]] as const) {
  test(`a run that ${preserve ? "keeps" : "drops"} its evidence ${stops ? "and stops its agent" : "but cannot stop its agent"} ${kept ? "keeps" : "removes"} the test instance`, async () => {
    const disposed: boolean[] = []
    const done = shutDown(async () => { if (!stops) throw new Error("still running") }, async (keep) => { disposed.push(keep) }, preserve)
    if (stops) await done
    else await assert.rejects(done, /still running/)
    assert.deepEqual(disposed, [kept])
  })
}

test("a command killed by a signal or one that never starts says so instead of failing with nothing", () => {
  assert.match(run("/bin/sh", ["-c", "kill -9 $$"]).why, /killed by SIGKILL/)
  assert.match(run("/bin/sleep", ["5"], { timeout: 0.2 }).why, /killed by SIGTERM/)
  assert.match(run("/nonexistent/tool", []).why, /ENOENT/)
  assert.equal(run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]).why, "out\nerr")
})

test("a command may be given a timeout that is not a whole number of milliseconds", () => {
  assert.equal(run("/bin/sh", ["-c", "exit 0"], { timeout: 130.24000000000001 }).status, 0)
})
