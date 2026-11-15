import assert from "node:assert/strict"
import { test } from "node:test"
import { keyscribe, promptDigest, shownThread, type Bb, type Host } from "../../Sources/KeyScribe/Resources/BBPlugin/keyscribe.ts"

type Request = { path: string; body: any; auth: string; answer: (status: number, text?: string) => void; settled: boolean; cancelled: boolean }

function harness(options: { threads?: { id: string; status: string }[]; history?: Record<string, string[]>; ready?: boolean } = {}) {
  const handlers = new Map<string, (payload: any) => void>()
  const logs: string[] = []
  const configuration: string[] = []
  const watchers: Array<{ path: string; fn: () => void; stopped: boolean }> = []
  const requests: Request[] = []
  const timers: Array<{ at: number; fn: () => void; id: number }> = []
  let timerId = 0
  let now = 1_000_000
  const config = {
    protocol: 3, socketPath: "/s/bridge.sock", tokenPath: "/s/token", readyPath: "/s/ready.json", installation: "I9",
    instance: "/Users/me/.bb", version: "1",
  }
  const files: Record<string, string | undefined> = {
    "/p/keyscribe.json": JSON.stringify(config),
    "/s/token": "secret\n",
    "/s/ready.json": options.ready === false ? undefined : JSON.stringify({ launch: "L1", protocol: 3 }),
  }
  const threads = options.threads ?? [{ id: "thr_a", status: "idle" }, { id: "thr_b", status: "active" }]
  const history = options.history ?? {}
  const bb: Bb = {
    listThreads: async () => threads,
    history: async (thread) => history[thread] ?? [],
    on: (event, handler) => { handlers.set(event, handler) },
  }
  const host: Host = {
    now: () => now,
    read: async (path) => {
      const text = files[path]
      if (text === undefined) throw new Error("ENOENT")
      return text
    },
    after: (ms, fn) => {
      const id = ++timerId
      timers.push({ at: now + ms, fn, id })
      return () => {
        const index = timers.findIndex((t) => t.id === id)
        if (index >= 0) timers.splice(index, 1)
      }
    },
    post: (socketPath, path, body, token) => {
      assert.equal(socketPath, "/s/bridge.sock")
      let resolve: (r: { status: number; ok: boolean; text: string }) => void = () => {}
      const response = new Promise<{ status: number; ok: boolean; text: string }>((r) => { resolve = r })
      const request: Request = {
        path, body: JSON.parse(body), auth: token, settled: false, cancelled: false,
        answer: (status, text = "") => {
          if (request.settled) return
          request.settled = true
          resolve({ status, ok: status >= 200 && status < 300, text })
        },
      }
      requests.push(request)
      return { response, cancel: () => { request.cancelled = true; request.answer(0) } }
    },
    random: () => "rnd",
    log: (message) => { logs.push(message) },
    needsConfiguration: (message) => { configuration.push(message) },
    watch: (path, fn) => {
      const watcher = { path, fn, stopped: false }
      watchers.push(watcher)
      return () => { watcher.stopped = true }
    },
  }
  const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)) }
  const advance = async (ms: number) => {
    now += ms
    for (;;) {
      const due = timers.filter((t) => t.at <= now).sort((a, b) => a.at - b.at)[0]
      if (!due) break
      timers.splice(timers.indexOf(due), 1)
      due.fn()
      await settle()
    }
    await settle()
  }
  const emit = async (event: string, payload: any) => {
    handlers.get(event)?.(payload)
    await settle()
  }
  const open = (op: string) => requests.filter((r) => !r.settled && (op === "poll" ? r.path === "/poll" : r.body.op === op))
  const sent = (op: string) => requests.filter((r) => r.path === "/event" && r.body.op === op).map((r) => r.body)
  const answerHellos = async () => {
    for (const r of open("hello")) r.answer(200, '{"ok":true}')
    await settle()
  }
  const answerEvents = async () => {
    for (const r of requests.filter((r) => !r.settled && r.path === "/event")) r.answer(200, '{"ok":true}')
    await settle()
  }
  const appStarted = async () => {
    for (const w of watchers.filter((w) => !w.stopped)) w.fn()
    await settle()
  }
  return { bb, host, files, requests, open, sent, emit, settle, advance, answerHellos, answerEvents, timers, logs, configuration, watchers, appStarted }
}

const session = (thread: string) => `${thread}@/Users/me/.bb`

async function connected(options: Parameters<typeof harness>[0] = {}) {
  const h = harness(options)
  const plugin = keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  await h.answerHellos()
  for (const r of h.requests.filter((r) => !r.settled && r.path === "/event" && r.body.op === "shown")) r.answer(200, '{"ok":true}')
  await h.settle()
  return Object.assign(h, { plugin })
}

test("says hello for every thread under its conversation key with what it knows, then one poll serves them all", async () => {
  const h = harness()
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  const hellos = h.sent("hello")
  assert.deepEqual(hellos.map((b) => b.session).sort(), [session("thr_a"), session("thr_b")])
  const a = hellos.find((b) => b.session === session("thr_a"))
  assert.equal(a.agent, "bb")
  assert.equal(a.protocol, 3)
  assert.equal(a.installation, "I9")
  assert.equal(a.pid, 0)
  assert.equal(a.idle, true)
  assert.deepEqual(a.features, ["promptDigest", "readiness", "shown"])
  assert.equal(hellos.find((b) => b.session === session("thr_b")).idle, false)
  assert.equal(new Set(hellos.map((b) => b.connection)).size, 1)
  assert.equal(new Set(hellos.map((b) => b.instance)).size, 2)
  assert.equal(h.requests[0].auth, "secret")
  assert.equal(h.open("poll").length, 0)
  await h.answerHellos()
  const polls = h.open("poll")
  assert.equal(polls.length, 1)
  assert.deepEqual(polls[0].body.members.map((m: any) => m.session).sort(), [session("thr_a"), session("thr_b")])
  assert.equal(polls[0].body.connection, hellos[0].connection)
})

test("many threads say hello a few at a time, so the app's backlog is never overrun", async () => {
  const threads = Array.from({ length: 20 }, (_, i) => ({ id: `thr_${i}`, status: "idle" }))
  const h = harness({ threads })
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  let most = 0
  for (let round = 0; round < 10 && h.open("hello").length; round++) {
    most = Math.max(most, h.open("hello").length)
    await h.answerHellos()
  }
  assert.equal(most, 8)
  assert.equal(h.sent("hello").length, 20)
  assert.equal(h.open("poll")[0].body.members.length, 20)
})

test("a thread id that would break the key is escaped the way the app keys hosted conversations", async () => {
  const h = await connected({ threads: [{ id: "t%1@x", status: "idle" }] })
  assert.equal(h.sent("hello")[0].session, "t%251%40x@/Users/me/.bb")
})

test("a dictation bb queued is followed by the text of the row that starts the turn", async () => {
  const h = await connected()
  await h.emit("message.queued", { entry: { id: "q1", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say kiwi" }] } })
  await h.emit("message.dispatched", { entry: { id: "q1", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say kiwi" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  const started = h.sent("turnStarted")
  assert.equal(started.length, 1)
  assert.equal(started[0].session, session("thr_a"))
  assert.equal(started[0].prompt, promptDigest("say kiwi"))
  const poll = h.open("poll")[0].body
  const member = poll.members.find((m: any) => m.session === session("thr_a"))
  assert.equal(started[0].instance, member.instance)
  assert.equal(started[0].connection, poll.connection)
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "kiwi" })
  const complete = h.sent("turnComplete")
  assert.deepEqual(
    complete.map((b) => [b.session, b.reason, b.answer]),
    [[session("thr_a"), "complete", "kiwi"]])
})

test("a turn bb started at once is named by the newest prompt in its history that is not still queued", async () => {
  const h = await connected({ history: { thr_a: ["typed later, still queued", "say plum", "older"] } })
  await h.emit("message.queued", { entry: { id: "q2", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "typed later, still queued" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  assert.equal(h.sent("turnStarted")[0].prompt, promptDigest("say plum"))
})

test("a turn bb itself started, or one whose prompt cannot be read, names no prompt", async () => {
  const h = await connected()
  await h.emit("message.dispatched", { entry: { id: "s1", threadId: "thr_a", initiator: "system", content: [{ type: "text", text: "[bb system] child finished" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  assert.equal(h.sent("turnStarted")[0].prompt, undefined)
  h.bb.history = async () => { throw new Error("gone") }
  await h.emit("thread.active", { thread: { id: "thr_b", status: "active" } })
  assert.equal(h.sent("turnStarted")[1].prompt, undefined)
})

test("a thread that goes idle without a turn the plugin saw start reports no reply", async () => {
  const h = await connected()
  await h.emit("thread.idle", { thread: { id: "thr_b", status: "idle" }, lastAssistantText: "already running before" })
  assert.equal(h.sent("turnComplete").length, 0)
})

test("a failed turn ends as an error and a long reply is cut to the bridge's bound", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.failed", { thread: { id: "thr_a", status: "error" }, error: "boom" })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.reason, b.answer]), [["error", ""]])
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "x".repeat(20000) })
  await h.answerEvents()
  assert.equal(h.sent("turnComplete")[1].answer.length, 8192)
})

test("every command a poll brings is acknowledged by the thread it was for, and the poll goes on", async () => {
  const h = await connected()
  const poll = h.open("poll")[0]
  const member = poll.body.members.find((m: any) => m.session === session("thr_b"))
  poll.answer(200, JSON.stringify({ commands: [{ op: "quiet", id: "c1", expectedSession: session("thr_b") }], unknown: [] }))
  await h.settle()
  const ack = h.sent("ack")
  assert.deepEqual(ack.map((b) => [b.request, b.instance, b.connection]), [["c1", member.instance, poll.body.connection]])
  assert.equal(h.open("poll").length, 1)
})

test("a thread the bridge no longer knows says hello again on its own", async () => {
  const h = await connected()
  const poll = h.open("poll")[0]
  const member = poll.body.members.find((m: any) => m.session === session("thr_b"))
  poll.answer(200, JSON.stringify({ commands: [], unknown: [member.instance] }))
  await h.settle()
  const again = h.open("hello")
  assert.deepEqual(again.map((r) => r.body.session), [session("thr_b")])
  await h.answerHellos()
  assert.equal(h.open("poll")[0].body.members.length, 2)
})

test("a conflict on the poll has every thread say hello again", async () => {
  const h = await connected()
  h.open("poll")[0].answer(409)
  await h.settle()
  assert.equal(h.open("hello").length, 2)
})

test("a new thread says hello and joins the poll, and an archived one leaves it", async () => {
  const h = await connected()
  await h.emit("thread.created", { thread: { id: "thr_c", status: "pending" } })
  assert.deepEqual(h.open("hello").map((r) => r.body.session), [session("thr_c")])
  await h.answerHellos()
  const polls = h.open("poll")
  assert.equal(polls.length, 1)
  assert.equal(polls[0].body.members.length, 3)
  assert.ok(h.requests.some((r) => r.path === "/poll" && r.cancelled))
  await h.emit("thread.archived", { thread: { id: "thr_c", status: "idle" } })
  assert.equal(h.open("poll")[0].body.members.length, 2)
})

test("retired, it stops talking to the app until bb restarts it", async () => {
  const h = await connected()
  h.open("poll")[0].answer(200, '[{"op":"retire","id":"retire"}]')
  await h.settle()
  const count = h.requests.length
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.advance(3_600_000)
  assert.equal(h.requests.length, count)
})

test("the settings are read from the first place they are found", async () => {
  const h = harness()
  h.files["/q/keyscribe.json"] = h.files["/p/keyscribe.json"]
  delete h.files["/p/keyscribe.json"]
  keyscribe(h.bb, h.host, ["/p/keyscribe.json", "/q/keyscribe.json"])
  await h.settle()
  assert.equal(h.open("hello").length, 2)
})

test("without its settings it asks bb to show it needs setting up, and never retries", async () => {
  const h = harness()
  delete h.files["/p/keyscribe.json"]
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  assert.equal(h.configuration.length, 1)
  assert.equal(h.timers.length, 0)
  assert.equal(h.requests.length, 0)
})

test("once disposed it sends nothing more, even when its startup finishes later", async () => {
  const h = await connected()
  h.plugin.stop()
  await h.settle()
  assert.ok(h.requests.filter((r) => r.path === "/poll").every((r) => r.settled))
  const count = h.requests.length
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.appStarted()
  await h.advance(3_600_000)
  assert.equal(h.requests.length, count)
  assert.ok(h.watchers.every((w) => w.stopped))
  const early = harness()
  const plugin = keyscribe(early.bb, early.host, ["/p/keyscribe.json"])
  plugin.stop()
  await early.settle()
  assert.equal(early.requests.length, 0)
})

test("a disconnected thread sends no reply or prompt, and sends them again once let back in", async () => {
  const h = harness()
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  for (const r of h.open("hello")) r.answer(200, r.body.session === session("thr_a") ? '{"ok":true,"quiet":true}' : '{"ok":true}')
  await h.settle()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "secret" })
  assert.equal(h.sent("turnStarted").length, 0)
  assert.equal(h.sent("turnComplete").length, 0)
  const poll = h.open("poll")[0]
  poll.answer(200, JSON.stringify({ commands: [{ op: "admit", id: "c1", expectedSession: session("thr_a") }], unknown: [] }))
  await h.settle()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  assert.equal(h.sent("turnStarted").length, 1)
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "quiet", id: "c2", expectedSession: session("thr_a") }], unknown: [] }))
  await h.settle()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "secret" })
  await h.answerEvents()
  assert.equal(h.sent("turnComplete").length, 0)
})

test("a thread it had not listed says hello as soon as bb reports it working", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_z", status: "active" } })
  const hello = h.open("hello")
  assert.deepEqual(hello.map((r) => r.body.session), [session("thr_z")])
  assert.equal(hello[0].body.idle, false)
})

test("refused by the app it stops and says why in bb's log", async () => {
  const h = harness()
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  for (const r of h.open("hello")) r.answer(403)
  await h.settle()
  assert.equal(h.open("poll").length, 0)
  assert.ok(h.logs.some((line) => line.includes("403")))
  await h.advance(3_600_000)
  assert.equal(h.open("hello").length, 0)
})

test("the app starting wakes it at once instead of at its next retry", async () => {
  const h = harness({ ready: false })
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  assert.equal(h.watchers.filter((w) => !w.stopped).map((w) => w.path).join(), "/s")
  h.files["/s/ready.json"] = JSON.stringify({ launch: "L2", protocol: 3 })
  await h.appStarted()
  assert.equal(h.open("hello").length, 2)
  assert.ok(h.logs.some((line) => line.includes("connected")))
})

test("while the app is not running nothing is sent, and it looks again later without piling up work", async () => {
  const h = harness({ ready: false })
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  assert.equal(h.requests.length, 0)
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  assert.equal(h.requests.length, 0)
  assert.equal(h.timers.length, 1)
  h.files["/s/ready.json"] = JSON.stringify({ launch: "L2", protocol: 3 })
  await h.advance(60_000)
  assert.equal(h.open("hello").length, 2)
  const hello = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.equal(hello.body.idle, false)
  assert.equal(h.open("hello").find((r) => r.body.session === session("thr_b")).body.idle, false)
})

test("an event the app cannot take is dropped, never replayed after reconnecting", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  for (const r of h.requests.filter((r) => !r.settled && r.path === "/event")) r.answer(0)
  await h.settle()
  h.open("poll")[0].answer(409)
  await h.settle()
  await h.answerHellos()
  assert.equal(h.sent("turnStarted").length, 1)
})

test("the digest is the one the app computes", () => {
  assert.equal(promptDigest(""), "cbf29ce484222325")
  assert.equal(promptDigest("a"), "af63dc4c8601ec8c")
  assert.equal(promptDigest("café"), "48e8823acfa40d89")
  assert.equal(promptDigest("​  a \n"), "af63dc4c8601ec8c")
})

const shownEvents = (h: { sent: (op: string) => any[] }) => h.sent("shown").slice(1).map((b) => [b.session, b.on])

async function answerShown(h: Awaited<ReturnType<typeof connected>>, status = 200) {
  for (const r of h.requests.filter((r) => !r.settled && r.path === "/event" && r.body.op === "shown")) r.answer(status, '{"ok":true}')
  await h.settle()
}

test("on connecting it first says that no thread is shown, since an earlier copy of it may have said one was", async () => {
  const h = await connected()
  assert.deepEqual(h.sent("shown").map((b) => b.on), [false])
})

test("a window shows a thread only on a thread page, and inside a split only once its focused pane agrees with the page", () => {
  assert.equal(shownThread("thr_a", null), "thr_a")
  assert.equal(shownThread(null, null), null)
  assert.equal(shownThread(null, [{ threadId: "thr_a", isFocused: true }, { threadId: "thr_b", isFocused: false }]), null)
  assert.equal(shownThread(null, [{ threadId: null, isFocused: true }, { threadId: "thr_b", isFocused: false }]), null)
  assert.equal(shownThread("thr_b", [{ threadId: "thr_a", isFocused: false }, { threadId: "thr_b", isFocused: true }]), "thr_b")
  assert.equal(shownThread("thr_a", [{ threadId: "thr_a", isFocused: false }, { threadId: "thr_b", isFocused: true }]), null)
  assert.equal(shownThread("thr_a", [{ threadId: "thr_a", isFocused: false }, { threadId: "thr_b", isFocused: false }]), "thr_a")
})

test("says which thread the most recently focused bb window shows, one at a time and in order, and nothing when none", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.settle()
  assert.deepEqual(shownEvents(h), [[session("thr_a"), true]])
  assert.equal(h.logs.filter((l) => l === "a bb window started reporting").length, 1)
  h.plugin.window({ window: "w2", focused: true, thread: "thr_b" })
  h.plugin.window({ window: "w1", focused: false, thread: "thr_a" })
  assert.equal(h.logs.filter((l) => l === "a bb window started reporting").length, 2)
  await h.settle()
  assert.equal(shownEvents(h).length, 1)
  await answerShown(h)
  assert.deepEqual(shownEvents(h).slice(1), [[session("thr_b"), true]])
  await answerShown(h)
  h.plugin.window({ window: "w2", focused: false, thread: "thr_b" })
  await h.settle()
  assert.equal(shownEvents(h).length, 2)
  h.plugin.window({ window: "w2", focused: false, thread: "thr_a" })
  await h.settle()
  assert.deepEqual(shownEvents(h).slice(2), [[session("thr_a"), true]])
  await answerShown(h)
  h.plugin.window({ window: "w2", focused: true, thread: null })
  await h.settle()
  assert.deepEqual(shownEvents(h).slice(3), [[session("thr_a"), false]])
})

test("a window focused now beats one whose blur was lost", async () => {
  const h = await connected()
  h.plugin.window({ window: "A", focused: true, thread: "thr_a" })
  await h.settle()
  await answerShown(h)
  h.plugin.window({ window: "B", focused: true, thread: "thr_b" })
  await h.settle()
  await answerShown(h)
  h.plugin.window({ window: "B", focused: false, thread: "thr_b" })
  h.plugin.window({ window: "A", focused: true, thread: "thr_a" })
  await h.settle()
  assert.deepEqual(shownEvents(h), [[session("thr_a"), true], [session("thr_b"), true], [session("thr_a"), true]])
})

test("a report the app did not take is sent again, and only the latest is sent", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.settle()
  await answerShown(h, 500)
  h.plugin.window({ window: "w1", focused: true, thread: "thr_b" })
  await h.settle()
  assert.deepEqual(shownEvents(h), [[session("thr_a"), true], [session("thr_b"), true]])
  for (const r of h.requests.filter((r) => !r.settled && r.body.op === "shown")) r.answer(0)
  await h.settle()
  await h.advance(5_000)
  assert.deepEqual(shownEvents(h).slice(2), [[session("thr_b"), true]])
  await answerShown(h)
  await h.advance(10_000)
  assert.equal(shownEvents(h).length, 3)
})

test("after the connection comes back it says again what is shown, even when focus moved while it was down", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.settle()
  await answerShown(h)
  h.open("poll")[0].answer(500)
  await h.settle()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_b" })
  await h.settle()
  assert.equal(shownEvents(h).length, 1)
  await h.advance(10_000)
  await h.answerHellos()
  assert.deepEqual(shownEvents(h).slice(1), [[session("thr_b"), true]])
})

test("after the app asks every thread to say hello again, it says again which thread is shown, or that none is", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.settle()
  await answerShown(h)
  h.open("poll")[0].answer(409)
  await h.settle()
  await h.answerHellos()
  assert.deepEqual(shownEvents(h), [[session("thr_a"), true], [session("thr_a"), true]])
  await answerShown(h)
  h.plugin.window({ window: "w1", focused: true, thread: null })
  await h.settle()
  await answerShown(h)
  h.open("poll")[0].answer(409)
  await h.settle()
  await h.answerHellos()
  assert.deepEqual(shownEvents(h).slice(2), [[session("thr_a"), false], [session("thr_a"), false]])
})

test("a disconnected thread is never reported as shown, and is once it is reconnected", async () => {
  const h = await connected()
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "quiet", id: "c1", expectedSession: session("thr_a") }] }))
  await h.settle()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.settle()
  assert.deepEqual(shownEvents(h), [[session("thr_b"), false]])
  await answerShown(h)
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "admit", id: "c2", expectedSession: session("thr_a") }] }))
  await h.settle()
  assert.deepEqual(shownEvents(h).slice(1), [[session("thr_a"), true]])
})

test("a thread bb had not listed is reported as shown once it arrives", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_new" })
  await h.settle()
  assert.deepEqual(shownEvents(h), [])
  await h.emit("thread.created", { thread: { id: "thr_new", status: "idle" } })
  await h.answerHellos()
  assert.deepEqual(shownEvents(h), [[session("thr_new"), true]])
})

test("a window that stops reporting is forgotten, so a reloaded window never stays in front", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.settle()
  await answerShown(h)
  await h.advance(10_000)
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a" })
  await h.advance(10_000)
  assert.deepEqual(shownEvents(h), [[session("thr_a"), true]])
  await h.advance(10_000)
  assert.deepEqual(shownEvents(h), [[session("thr_a"), true], [session("thr_a"), false]])
})
