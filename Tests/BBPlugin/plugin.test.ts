import assert from "node:assert/strict"
import { test } from "node:test"
import { focusConnectionContract } from "../AgentConformance/lib/focus-contract.ts"
import { ComposerAnswers, acceptedInEndedTurn, commandAnswer, composeInto, keyscribe, promptDigest, readAloudReply, rowLabel, spokenMentions, shownThread, waitingFor, type Bb, type Composed, type Host } from "../../Sources/KeyScribe/Resources/BBPlugin/keyscribe.ts"

type Request = { path: string; body: any; auth: string; answer: (status: number, text?: string) => void; settled: boolean; cancelled: boolean }

function harness(options: { threads?: { id: string; status: string }[]; history?: Record<string, string[]>; inputs?: Record<string, string[] | null>; ready?: boolean } = {}) {
  const at = 5_000
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
    instance: "/Users/me/.bb", version: "1", appName: "KeyScribe",
  }
  const files: Record<string, string | undefined> = {
    "/p/keyscribe.json": JSON.stringify(config),
    "/s/token": "secret\n",
    "/s/ready.json": options.ready === false ? undefined : JSON.stringify({ launch: "L1", protocol: 3 }),
  }
  const threads = options.threads ?? [{ id: "thr_a", status: "idle" }, { id: "thr_b", status: "active" }]
  const history = options.history ?? {}
  const inputs = options.inputs ?? {}
  const asks: Array<{ thread: string; failed: boolean; since: number | null }> = []
  const interactions: Record<string, string | Error> = {}
  const checked: string[] = []
  let labelChanges = 0
  const composes: Array<{ window: string; thread: string | null; text: string }> = []
  const composing: { answer: Composed | null } = { answer: { outcome: "sent", joined: "half a thought run the tests" } }
  const bb: Bb = {
    listThreads: async () => threads,
    history: async (thread) => history[thread] ?? [],
    turnInputs: async (thread, failed, since) => {
      asks.push({ thread, failed, since })
      return inputs[thread]?.map((said) => ({ said, at })) ?? null
    },
    interaction: async (thread, id) => {
      checked.push(`${thread}/${id}`)
      const status = interactions[id]
      if (status instanceof Error) throw status
      return status ?? null
    },
    on: (event, handler) => { handlers.set(event, handler) },
    compose: async (window, thread, text) => {
      composes.push({ window, thread, text })
      return composing.answer
    },
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
    labelled: () => { labelChanges += 1 },
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
  return {
    bb, host, files, requests, open, sent, emit, settle, advance, answerHellos, answerEvents, timers, logs, configuration, watchers, appStarted,
    interactions, checked, labelChanges: () => labelChanges,
    composes, composing, asks,
  }
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

focusConnectionContract("bb", async () => {
  const h = harness()
  const plugin = keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  return {
    focus: async focused => { plugin.window({ window: "w1", focused: true, thread: focused ? "thr_a" : null }); await h.settle() },
    connect: h.answerHellos,
    drain: async () => { for (let i = 0; i < 4; i++) await h.answerEvents() },
    reports: () => h.sent("shown"),
    stop: plugin.stop,
  }
})

test("says hello for every thread under its conversation key with what it knows, then one poll serves them all", async () => {
  const h = harness()
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  const hellos = h.sent("hello")
  assert.deepEqual(hellos.map((b) => b.session).sort(), [session("new conversation"), session("thr_a"), session("thr_b")])
  const a = hellos.find((b) => b.session === session("thr_a"))
  assert.equal(a.agent, "bb")
  assert.equal(a.protocol, 3)
  assert.equal(a.installation, "I9")
  assert.equal(a.pid, 0)
  assert.equal(a.idle, true)
  assert.deepEqual(a.features, ["promptDigest", "readiness", "shown", "notify", "label", "merge", "start", "accepted"])
  assert.equal(hellos.find((b) => b.session === session("thr_b")).idle, false)
  assert.equal(new Set(hellos.map((b) => b.connection)).size, 1)
  assert.equal(new Set(hellos.map((b) => b.instance)).size, 3)
  assert.equal(h.requests[0].auth, "secret")
  assert.equal(h.open("poll").length, 0)
  await h.answerHellos()
  const polls = h.open("poll")
  assert.equal(polls.length, 1)
  assert.deepEqual(polls[0].body.members.map((m: any) => m.session).sort(), [session("new conversation"), session("thr_a"), session("thr_b")])
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
  assert.equal(h.sent("hello").length, 21)
  assert.equal(h.open("poll")[0].body.members.length, 21)
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
    complete.map((b) => [b.session, b.reason, b.answer, b.from, b.prompt]),
    [[session("thr_a"), "complete", "kiwi", undefined, promptDigest("say kiwi")]])
})

test("a reply to a turn bb itself started says it came from someone else and names no prompt", async () => {
  const h = await connected()
  await h.emit("message.dispatched", { entry: { id: "s1", threadId: "thr_a", initiator: "system", content: [{ type: "text", text: "[bb system] child finished" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "The child is done." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.from, b.prompt]), [["other", undefined]])
})

test("a reply reported late after the next turn took in a message names nothing and never erases that turn’s attribution", async () => {
  const h = await connected()
  await h.emit("message.dispatched", { entry: { id: "q1", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say kiwi" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "kiwi" })
  await h.emit("message.dispatched", { entry: { id: "q2", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say fig" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("message.dispatched", { entry: { id: "a1", threadId: "thr_a", initiator: "agent", content: [{ type: "text", text: "also check plum" }] } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Plum checked." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.answer, b.from, b.prompt]), [
    ["kiwi", undefined, undefined],
    ["Plum checked.", "agent", promptDigest("also check plum")],
  ])
})

test("a turn’s start reported only after the next turn took in a message never takes that turn’s attribution", async () => {
  const h = await connected()
  await h.emit("message.dispatched", { entry: { id: "q0", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say pear" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "pear" })
  await h.emit("message.dispatched", { entry: { id: "q1", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say kiwi" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "kiwi" })
  await h.emit("message.dispatched", { entry: { id: "q2", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say fig" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("message.dispatched", { entry: { id: "a1", threadId: "thr_a", initiator: "agent", content: [{ type: "text", text: "also check plum" }] } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Plum checked." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.answer, b.from, b.prompt]), [
    ["pear", undefined, promptDigest("say pear")],
    ["kiwi", undefined, undefined],
    ["Plum checked.", "agent", promptDigest("also check plum")],
  ])
})

test("a reply after another agent’s message names that agent, and one after a message taken into the running turn is tied to that message", async () => {
  const h = await connected()
  await h.emit("message.dispatched", { entry: { id: "a1", threadId: "thr_a", initiator: "agent", content: [{ type: "text", text: "found a race" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Fixed the race." })
  await h.answerEvents()
  await h.emit("message.dispatched", { entry: { id: "q1", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say kiwi" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("message.dispatched", { entry: { id: "a2", threadId: "thr_a", initiator: "agent", content: [{ type: "text", text: "also check plum" }] } })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Plum checked." })
  await h.answerEvents()
  await h.emit("message.dispatched", { entry: { id: "q2", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "say fig" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("message.dispatched", { entry: { id: "q3", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "and grape" }] } })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Fig and grape." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.from, b.prompt]), [
    ["agent", promptDigest("found a race")],
    ["agent", promptDigest("also check plum")],
    [undefined, promptDigest("and grape")],
  ])
  assert.deepEqual(h.sent("turnStarted").map((b) => b.prompt), [promptDigest("found a race"), promptDigest("say kiwi"), promptDigest("say fig")])
})

test("a turn that took several messages reports every one bb accepted into it, read from bb's own record", async () => {
  const h = await connected({ inputs: { thr_a: ["say kiwi", "and grape"] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Kiwi and grape." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => b.accepted), [[{ digest: promptDigest("say kiwi"), at: 5_000 }, { digest: promptDigest("and grape"), at: 5_000 }]])
})

test("a joined draft bb accepted is reported as the dictation it carried", async () => {
  const h = await connected({ history: { thr_a: ["half a thought run the tests"] }, inputs: { thr_a: ["half a thought run the tests"] } })
  await shownIn(h, "thr_a")
  await mergeCommand(h)
  await h.answerEvents()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Tests pass." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => b.accepted), [[{ digest: promptDigest("run the tests"), at: 5_000 }]])
})

test("a turn whose record bb could not give reports no accepted messages rather than an empty list", async () => {
  const h = await connected()
  h.bb.turnInputs = async () => { throw new Error("gone") }
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "done" })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => "accepted" in b), [false])
})

test("the messages a turn took are the ones bb accepted into the turn that ended, each with when bb recorded it", () => {
  const row = (seq: number, createdAt: number, type: string, scope: object, data: object) => ({ seq, createdAt, type, scope, data })
  const asked = (seq: number, at: number, requestId: string, said: string) =>
    row(seq, at, "client/turn/requested", { kind: "thread" }, { requestId, input: [{ type: "text", text: said, mentions: [] }] })
  const took = (seq: number, at: number, turnId: string, clientRequestId: string) =>
    row(seq, at, "turn/input/accepted", { kind: "turn", turnId }, { clientRequestId })
  const rows = [
    row(64, 9_000, "turn/completed", { kind: "turn", turnId: "t2" }, { status: "completed" }),
    took(49, 8_000, "t2", "creq_two"),
    asked(48, 8_000, "creq_two", "also reply with two"),
    took(35, 7_000, "t2", "creq_one"),
    row(34, 7_000, "turn/started", { kind: "turn", turnId: "t2" }, {}),
    asked(33, 7_000, "creq_one", "reply with one"),
    row(31, 2_000, "turn/completed", { kind: "turn", turnId: "t1" }, { status: "completed" }),
    took(15, 1_000, "t1", "creq_zero"),
    row(14, 1_000, "turn/started", { kind: "turn", turnId: "t1" }, {}),
    asked(1, 1_000, "creq_zero", "reply with ready"),
  ]
  const two = [{ said: "reply with one", at: 7_000 }, { said: "also reply with two", at: 8_000 }]
  assert.deepEqual(acceptedInEndedTurn(rows, false, 7_000), two)
  assert.deepEqual(acceptedInEndedTurn({ events: rows }, false, null), two)
  assert.equal(acceptedInEndedTurn(rows, false, 20_000), null)
  assert.equal(acceptedInEndedTurn([asked(1, 1_000, "creq_zero", "reply with ready")], false, null), null)
  assert.equal(acceptedInEndedTurn("nonsense", false, null), null)
  const failedUnrecorded = [row(70, 12_000, "turn/started", { kind: "turn", turnId: "t3" }, {}), took(71, 12_000, "t3", "creq_three"),
    asked(69, 12_000, "creq_three", "try three"), ...rows]
  assert.deepEqual(acceptedInEndedTurn(failedUnrecorded, true, 12_000), [{ said: "try three", at: 12_000 }])
  assert.equal(acceptedInEndedTurn(failedUnrecorded, false, 12_000), null)
  const failedRecorded = [row(72, 13_000, "turn/completed", { kind: "turn", turnId: "t3" }, { status: "failed" }), ...failedUnrecorded]
  assert.deepEqual(acceptedInEndedTurn(failedRecorded, true, 12_000), [{ said: "try three", at: 12_000 }])
})

test("a turn whose record bb could not give in time reports no accepted messages, and later reports still land", async () => {
  const h = await connected()
  h.bb.turnInputs = () => new Promise(() => {})
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "done" })
  await h.advance(10_000)
  await h.answerEvents()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => "accepted" in b), [false])
  assert.equal(h.sent("turnStarted").length, 2)
})

test("a turn bb took a message into that its record cannot place gives no list rather than a shorter one", () => {
  const row = (seq: number, createdAt: unknown, type: string, scope: object, data: object) => ({ seq, createdAt, type, scope, data })
  const asked = (seq: number, at: unknown, requestId: string, said: string, retryOf?: string) =>
    row(seq, at, "client/turn/requested", { kind: "thread" },
      { requestId, input: [{ type: "text", text: said, mentions: [] }], ...(retryOf ? { retryOfRequestId: retryOf, retryAttempt: 2 } : {}) })
  const took = (seq: number, at: number, turnId: string, clientRequestId: string) =>
    row(seq, at, "turn/input/accepted", { kind: "turn", turnId }, { clientRequestId })
  const turn = (accepted: object[]) => [
    row(90, 9_000, "turn/completed", { kind: "turn", turnId: "t1" }, { status: "completed" }),
    ...accepted,
    row(10, 1_000, "turn/started", { kind: "turn", turnId: "t1" }, {}),
  ]
  assert.equal(acceptedInEndedTurn(turn([took(20, 2_000, "t1", "creq_one"), took(21, 2_000, "t1", "creq_gone"), asked(5, 1_000, "creq_one", "one")]), false, null), null)
  assert.equal(acceptedInEndedTurn(turn([took(20, 2_000, "t1", "creq_one"), asked(5, "1970-01-01T00:00:01Z", "creq_one", "one")]), false, null), null)
  assert.deepEqual(acceptedInEndedTurn(turn([]), false, null), [])
  const pictureOnly = row(6, 1_500, "client/turn/requested", { kind: "thread" }, { requestId: "creq_picture", input: [{ type: "image", path: "/x.png" }] })
  assert.deepEqual(
    acceptedInEndedTurn(turn([took(20, 2_000, "t1", "creq_picture"), took(21, 2_000, "t1", "creq_one"), pictureOnly, asked(5, 1_000, "creq_one", "one")]), false, null),
    [{ said: "", at: 1_500 }, { said: "one", at: 1_000 }])
  const fromAnotherThread = row(7, 1_700, "client/turn/requested", { kind: "thread" },
    { requestId: "creq_child", initiator: "agent", senderThreadId: "thr_child", input: [{ type: "text", text: "child finished", mentions: [] }] })
  assert.deepEqual(
    acceptedInEndedTurn(turn([took(20, 2_000, "t1", "creq_child"), fromAnotherThread]), false, null),
    [{ said: "child finished", at: 1_700 }])
  assert.deepEqual(
    acceptedInEndedTurn(turn([took(20, 8_000, "t1", "creq_retry"), asked(15, 7_000, "creq_retry", "one", "creq_one"), asked(5, 1_000, "creq_one", "one")]), false, null),
    [{ said: "one", at: 1_000 }])
})

test("a note bb itself wrote into a turn is listed as bb's own, after the dictation it followed", () => {
  const row = (seq: number, createdAt: number, type: string, scope: object, data: object) => ({ seq, createdAt, type, scope, data })
  const asked = (seq: number, at: number, requestId: string, said: string, initiator: string) =>
    row(seq, at, "client/turn/requested", { kind: "thread" }, { requestId, initiator, input: [{ type: "text", text: said, mentions: [] }] })
  const took = (seq: number, at: number, clientRequestId: string) => row(seq, at, "turn/input/accepted", { kind: "turn", turnId: "t1" }, { clientRequestId })
  const rows = [
    row(90, 9_000, "turn/completed", { kind: "turn", turnId: "t1" }, { status: "completed" }),
    took(31, 3_000, "creq_note"),
    asked(30, 3_000, "creq_note", "[bb system]\n\n@thread:thr_child completed", "system"),
    took(21, 2_000, "creq_said"),
    asked(20, 2_000, "creq_said", "name three fruits", "user"),
    row(10, 2_000, "turn/started", { kind: "turn", turnId: "t1" }, {}),
  ]
  assert.deepEqual(acceptedInEndedTurn(rows, false, null), [
    { said: "name three fruits", at: 2_000 },
    { said: "[bb system]\n\n@thread:thr_child completed", at: 3_000, host: true },
  ])
})

test("a note bb itself adds to a turn that took a dictation never replaces the dictation the turn answers", async () => {
  const h = await connected({ inputs: { thr_a: [] } })
  h.bb.turnInputs = async () => [{ said: "name three fruits", at: 5_000 }, { said: "[bb system] child completed", at: 5_100, host: true }]
  await h.emit("message.dispatched", { entry: { id: "q1", threadId: "thr_a", initiator: "user", content: [{ type: "text", text: "name three fruits" }] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("message.dispatched", { entry: { id: "s1", threadId: "thr_a", initiator: "system", content: [{ type: "text", text: "[bb system] child completed" }] } })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "Apple. Mango. Pear." })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.from, b.prompt, b.accepted]), [[undefined, promptDigest("name three fruits"), [
    { digest: promptDigest("name three fruits"), at: 5_000 },
    { digest: promptDigest("[bb system] child completed"), at: 5_100, host: true },
  ]]])
})

test("a failed turn's record is asked for as a failed turn, and the record is asked for when the turn ends, before earlier reports land", async () => {
  const h = await connected({ inputs: { thr_a: ["say kiwi"] } })
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.emit("thread.failed", { thread: { id: "thr_a", status: "error" } })
  assert.deepEqual(h.asks.map((a) => [a.thread, a.failed, typeof a.since]), [["thr_a", true, "number"]])
  await h.answerEvents()
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.reason, b.accepted]), [["error", [{ digest: promptDigest("say kiwi"), at: 5_000 }]]])
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

test("a thread that goes idle with no turn running, as far as the plugin knows, reports no reply", async () => {
  const h = await connected()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "nothing ran" })
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

test("the name the app gives a thread is kept for that thread, acknowledged, and redrawn", async () => {
  const h = await connected()
  assert.deepEqual(h.plugin.labels(["thr_a", "thr_b"]), { thr_a: null, thr_b: null })
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "status", id: "c1", expectedSession: session("thr_b"), text: "“scratch repo blue”" }], unknown: [] }))
  await h.settle()
  assert.deepEqual(h.plugin.labels(["thr_a", "thr_b", "thr_gone"]), { thr_a: null, thr_b: "“scratch repo blue”", thr_gone: null })
  assert.equal(h.labelChanges(), 1)
  assert.deepEqual(h.sent("ack").map((b) => b.request), ["c1"])
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "status", id: "c2", expectedSession: session("thr_b"), text: "“scratch repo blue”" }], unknown: [] }))
  await h.settle()
  assert.equal(h.labelChanges(), 1)
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "status", id: "c3", expectedSession: session("thr_b"), text: 7 }], unknown: [] }))
  await h.settle()
  assert.deepEqual(h.plugin.labels(["thr_b"]), { thr_b: "“scratch repo blue”" })
  await h.emit("thread.archived", { thread: { id: "thr_b" } })
  assert.deepEqual(h.plugin.labels(["thr_b"]), { thr_b: null })
})

async function named(h: Awaited<ReturnType<typeof connected>>) {
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "status", id: "c1", expectedSession: session("thr_b"), text: "“scratch repo blue”" }], unknown: [] }))
  await h.settle()
  assert.equal(h.labelChanges(), 1)
}

for (const [how, end] of [
  ["finds the app no longer running", async (h: any) => {
    h.files["/s/ready.json"] = undefined
    h.open("poll")[0].answer(500)
    await h.settle()
    await h.advance(10_000)
  }],
  ["finds the app was relaunched", async (h: any) => {
    h.files["/s/ready.json"] = JSON.stringify({ launch: "L2", protocol: 3 })
    h.open("poll")[0].answer(500)
    await h.settle()
    await h.advance(10_000)
  }],
  ["is retired by the app", async (h: any) => {
    h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "retire", id: "r1" }], unknown: [] }))
    await h.settle()
  }],
] as const) {
  test(`a name the app gave is no longer drawn once the plugin ${how}, since nothing could correct it`, async () => {
    const h = await connected()
    await named(h)
    await end(h)
    assert.deepEqual(h.plugin.labels(["thr_b"]), { thr_b: null })
    assert.equal(h.labelChanges(), 2)
  })
}

test("a name the app gave is kept through a brief loss of the connection to the same launch of the app", async () => {
  const h = await connected()
  await named(h)
  h.open("poll")[0].answer(500)
  await h.settle()
  assert.deepEqual(h.plugin.labels(["thr_b"]), { thr_b: "“scratch repo blue”" })
  await h.advance(10_000)
  assert.ok(h.open("poll").length + h.open("hello").length > 0)
  assert.deepEqual(h.plugin.labels(["thr_b"]), { thr_b: "“scratch repo blue”" })
  assert.equal(h.labelChanges(), 1)
})

test("a name is drawn beside a thread only when it says something its bb title does not", () => {
  assert.equal(rowLabel("“scratch repo blue”", null), "scratch repo blue")
  assert.equal(rowLabel("“scratch repo blue”", "what time is it?"), "scratch repo blue")
  assert.equal(rowLabel("“Docs”", "  docs "), null)
  assert.equal(rowLabel("“Docs  Fix”", "docs fix"), null)
  assert.equal(rowLabel("“ks probe claude”", "ks-probe claude"), null)
  assert.equal(rowLabel("“ks probe”", "Ks: probe!"), null)
  assert.equal(rowLabel("“ks probe two”", "ks-probe claude"), "ks probe two")
  assert.equal(rowLabel(null, "docs"), null)
  assert.equal(rowLabel(undefined, null), null)
  assert.equal(rowLabel("“ ”", null), null)
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
  assert.equal(h.open("poll")[0].body.members.length, 3)
})

test("a conflict on the poll has every thread say hello again", async () => {
  const h = await connected()
  h.open("poll")[0].answer(409)
  await h.settle()
  assert.equal(h.open("hello").length, 3)
})

test("a new thread says hello and joins the poll, and an archived one leaves it", async () => {
  const h = await connected()
  await h.emit("thread.created", { thread: { id: "thr_c", status: "pending" } })
  assert.deepEqual(h.open("hello").map((r) => r.body.session), [session("thr_c")])
  await h.answerHellos()
  const polls = h.open("poll")
  assert.equal(polls.length, 1)
  assert.equal(polls[0].body.members.length, 4)
  assert.ok(h.requests.some((r) => r.path === "/poll" && r.cancelled))
  await h.emit("thread.archived", { thread: { id: "thr_c", status: "idle" } })
  assert.equal(h.open("poll")[0].body.members.length, 3)
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
  assert.equal(h.open("hello").length, 3)
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
  assert.equal(h.open("hello").length, 3)
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
  assert.equal(h.open("hello").length, 3)
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

const approval = (subject: object, reason: string | null = null) => ({ id: "i1", status: "pending", threadId: "thr_a", payload: { kind: "approval", reason, availableDecisions: ["allow_once", "deny"], subject } })

test("a prompt bb waits on is described the way the app describes any agent's prompt, with a title only where bb gives one", () => {
  assert.deepEqual(waitingFor(approval({ kind: "command", command: "curl example.com", cwd: "/src", itemId: "x", actions: [], sessionGrant: null }, "Needs the network")),
    { kind: "confirm", title: "Needs the network", tool: "command", detail: "curl example.com" })
  assert.deepEqual(waitingFor(approval({ kind: "file_change", itemId: "x", sessionGrant: null, writeScope: "/src/app" })),
    { kind: "confirm", detail: "/src/app" })
  assert.deepEqual(waitingFor(approval({ kind: "permission_grant", itemId: "x", toolName: "Bash", permissions: { fileSystem: null, network: null } }, "Run tests")),
    { kind: "confirm", title: "Run tests", tool: "Bash" })
  assert.deepEqual(waitingFor(approval({ kind: "plan", itemId: "x", plan: "1. Fix it", planFilePath: null })),
    { kind: "confirm", detail: "1. Fix it" })
  assert.deepEqual(waitingFor(approval({ kind: "tool_use", itemId: "x", tool: "deploy", presentation: { icon: { glyph: "x" }, label: { pending: "Deploying", completed: "Deployed" }, detail: "to staging" } })),
    { kind: "confirm", title: "Deploying", tool: "deploy", detail: "to staging" })
  const question = (options?: object[]) => ({ id: "i2", status: "pending", threadId: "thr_a", payload: { kind: "user_question", questions: [{ id: "q", prompt: "Which branch?", allowFreeText: false, multiSelect: false, required: true, options }] } })
  assert.deepEqual(waitingFor(question([{ label: "main", value: "m" }, { label: "dev", value: "d" }])), { kind: "select", title: "Which branch?", detail: "main, dev" })
  assert.deepEqual(waitingFor(question()), { kind: "input", title: "Which branch?" })
  assert.deepEqual(waitingFor({ id: "i3", status: "pending", payload: { kind: "acme/login", title: "Sign in to Acme", data: {} } }), { kind: "custom", title: "Sign in to Acme" })
  assert.deepEqual(waitingFor({ id: "i4", status: "pending", payload: { kind: "plugin", title: "Pick a color", data: {} } }), { kind: "custom", title: "Pick a color" })
  assert.deepEqual(waitingFor({ id: "i5", status: "pending", payload: null }), {})
  const long = waitingFor(approval({ kind: "command", command: "x".repeat(5000), cwd: null, itemId: "x", actions: [], sessionGrant: null }, "y".repeat(5000)))
  assert.equal(long.title?.length, 300)
  assert.equal(long.detail?.length, 1000)
})

test("a prompt bb waits on is reported, and cleared once bb no longer waits on it, checking only while it waits", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: approval({ kind: "command", command: "ls", cwd: null, itemId: "x", actions: [], sessionGrant: null }) })
  await h.answerEvents()
  assert.deepEqual(h.sent("waiting").map((b) => [b.session, b.waiting]), [[session("thr_a"), { kind: "confirm", tool: "command", detail: "ls" }]])
  await h.advance(5000)
  await h.answerEvents()
  assert.equal(h.sent("waiting").length, 1)
  assert.deepEqual(h.checked, ["thr_a/i1"])
  h.interactions.i1 = "resolved"
  await h.advance(5000)
  await h.answerEvents()
  assert.deepEqual(h.sent("waiting").map((b) => [b.session, b.waiting]), [[session("thr_a"), { kind: "confirm", tool: "command", detail: "ls" }], [session("thr_a"), undefined]])
  await h.advance(60_000)
  assert.equal(h.checked.length, 2)
})

test("a prompt whose check fails is still waited on, and one bb no longer has is cleared", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  h.interactions.i1 = new Error("busy")
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: approval({ kind: "plan", itemId: "x", plan: "p", planFilePath: null }) })
  await h.advance(5000)
  await h.answerEvents()
  assert.equal(h.sent("waiting").length, 1)
  delete h.interactions.i1
  await h.advance(5000)
  await h.answerEvents()
  assert.equal(h.sent("waiting").length, 2)
  assert.equal(h.sent("waiting")[1].waiting, undefined)
})

test("a turn that ends stops the wait before its reply, and an answered prompt never resurfaces", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: approval({ kind: "plan", itemId: "x", plan: "p", planFilePath: null }) })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "done" })
  await h.answerEvents()
  await h.answerEvents()
  await h.answerEvents()
  const ops = h.requests.filter((r) => r.path === "/event" && ["waiting", "turnComplete"].includes(r.body.op)).map((r) => [r.body.op, r.body.waiting])
  assert.deepEqual(ops, [["waiting", { kind: "confirm", detail: "p" }], ["waiting", undefined], ["turnComplete", undefined]])
  await h.advance(60_000)
  assert.equal(h.checked.length, 0)
})

test("a prompt already answered when bb reports it is not reported", async () => {
  const h = await connected()
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: { ...approval({ kind: "plan", itemId: "x", plan: "p", planFilePath: null }), status: "resolved" } })
  await h.answerEvents()
  assert.equal(h.sent("waiting").length, 0)
})

test("a prompt still open when the thread says hello again is in that hello", async () => {
  const h = await connected()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: approval({ kind: "plan", itemId: "x", plan: "p", planFilePath: null }) })
  await h.answerEvents()
  h.open("poll")[0].answer(409)
  await h.settle()
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.deepEqual(again?.body.waiting, { kind: "confirm", detail: "p" })
  assert.equal(h.open("hello").find((r) => r.body.session === session("thr_b"))?.body.waiting, undefined)
})

test("asked from inside a thread, it asks the app to read that thread's current turn aloud and says what the app answered", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  const turn = h.sent("turnStarted")[0].turn
  const asked = h.plugin.readAloud("thr_a")
  await h.settle()
  const request = h.open("notify")[0]
  assert.deepEqual([request.body.session, request.body.turn, request.body.on], [session("thr_a"), turn, true])
  request.answer(200, '{"ok":true,"spoken":true}')
  assert.equal(await asked, true)
  for (const [text, expected] of [['{"ok":true,"spoken":false}', false], ['{"ok":true,"quiet":true}', "quiet"], ["nope", null]] as const) {
    const again = h.plugin.readAloud("thr_a")
    await h.settle()
    h.open("notify")[0].answer(200, text)
    assert.equal(await again, expected)
  }
  const failed = h.plugin.readAloud("thr_a")
  await h.settle()
  h.open("notify")[0].answer(500)
  assert.equal(await failed, null)
})

test("asked from a thread it cannot reach, it promises nothing and sends nothing", async () => {
  const h = await connected()
  assert.equal(await h.plugin.readAloud("thr_unknown"), null)
  const quiet = harness()
  const plugin = keyscribe(quiet.bb, quiet.host, ["/p/keyscribe.json"])
  await quiet.settle()
  for (const r of quiet.open("hello")) r.answer(200, '{"ok":true,"quiet":true}')
  await quiet.settle()
  assert.equal(await plugin.readAloud("thr_a"), "quiet")
  const down = harness({ ready: false })
  const idle = keyscribe(down.bb, down.host, ["/p/keyscribe.json"])
  await down.settle()
  assert.equal(await idle.readAloud("thr_a"), null)
  assert.equal(h.sent("notify").length + quiet.sent("notify").length + down.sent("notify").length, 0)
})

test("asked between turns, it asks for the thread's next reply", async () => {
  const h = await connected()
  const asked = h.plugin.readAloud("thr_a")
  await h.settle()
  assert.equal(h.open("notify")[0].body.turn, "")
  h.open("notify")[0].answer(200, '{"ok":true,"spoken":true}')
  assert.equal(await asked, true)
})

test("the agent is told plainly what the app promised", () => {
  assert.match(readAloudReply("KeyScribe", true), /KeyScribe will report your final reply/)
  assert.match(readAloudReply("KeyScribe", false), /Read Agent Replies Aloud is off/)
  assert.match(readAloudReply("KeyScribe", "quiet"), /disconnected/)
  assert.match(readAloudReply("KeyScribe", null), /didn’t confirm the request, so the reply may not be reported\. Tell the user\.$/)
})

const plan = approval({ kind: "plan", itemId: "x", plan: "p", planFilePath: null })

test("a prompt report the app did not take has the thread say hello again with the prompt, so it is never lost", async () => {
  const h = await connected()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  h.open("waiting")[0].answer(500)
  await h.settle()
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.deepEqual(again?.body.waiting, { kind: "confirm", detail: "p" })
})

test("a cleared prompt the app did not take has the thread say hello again without it", async () => {
  const h = await connected()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  await h.answerEvents()
  h.interactions.i1 = "resolved"
  await h.advance(5000)
  h.open("waiting")[0].answer(0)
  await h.settle()
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.ok(again)
  assert.equal(again.body.waiting, undefined)
})

test("a prompt that opens while the app is unreachable is in the hello once it is back", async () => {
  const h = await connected()
  h.open("poll")[0].answer(500)
  await h.settle()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  assert.equal(h.sent("waiting").length, 0)
  await h.advance(10_000)
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.deepEqual(again?.body.waiting, { kind: "confirm", detail: "p" })
})

test("a thread let back in says hello again, so the app learns the prompt it waits on now", async () => {
  const h = harness()
  keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  await h.settle()
  for (const r of h.open("hello")) r.answer(200, r.body.session === session("thr_a") ? '{"ok":true,"quiet":true}' : '{"ok":true}')
  await h.settle()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  assert.equal(h.sent("waiting").length, 0)
  h.open("poll")[0].answer(200, JSON.stringify({ commands: [{ op: "admit", id: "c1", expectedSession: session("thr_a") }], unknown: [] }))
  await h.settle()
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.deepEqual(again?.body.waiting, { kind: "confirm", detail: "p" })
})

test("a prompt left open is checked every few seconds at first and then less often", async () => {
  const h = await connected()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  for (let i = 0; i < 12; i++) await h.advance(5000)
  const early = h.checked.length
  assert.equal(early, 12)
  for (let i = 0; i < 60; i++) await h.advance(5000)
  assert.equal(h.checked.length - early, 10)
})

test("a turn already running when it starts is taken as the thread's current turn, so it can be read aloud and ends with a reply", async () => {
  const h = await connected()
  const hello = h.sent("hello").find((b) => b.session === session("thr_b"))
  assert.equal(typeof hello.turn, "string")
  assert.equal(h.sent("hello").find((b) => b.session === session("thr_a")).turn, undefined)
  const asked = h.plugin.readAloud("thr_b")
  await h.settle()
  const request = h.open("notify")[0]
  assert.equal(request.body.turn, hello.turn)
  request.answer(200, '{"ok":true,"spoken":true}')
  assert.equal(await asked, true)
  await h.emit("thread.idle", { thread: { id: "thr_b", status: "idle" }, lastAssistantText: "finished" })
  await h.answerEvents()
  assert.deepEqual(h.sent("turnComplete").map((b) => [b.session, b.answer]), [[session("thr_b"), "finished"]])
})

test("a hello said again mid-turn names the turn, so a promised reply is not taken back", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  const turn = h.sent("turnStarted")[0].turn
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  h.open("waiting")[0].answer(0)
  await h.settle()
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.equal(again?.body.turn, turn)
  assert.deepEqual(again?.body.waiting, { kind: "confirm", detail: "p" })
})

test("a failed prompt report never drops the reply queued behind it", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "done" })
  h.open("waiting")[0].answer(0)
  await h.settle()
  for (let i = 0; i < 4; i++) {
    await h.answerHellos()
    await h.answerEvents()
  }
  assert.deepEqual(h.sent("turnComplete").map((b) => b.answer), ["done"])
})

test("asked while its earlier reports are stuck, it answers within its own deadline and promises nothing", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  let answer: unknown = "unanswered"
  void h.plugin.readAloud("thr_a").then((a) => { answer = a })
  await h.settle()
  assert.equal(answer, "unanswered")
  await h.advance(4000)
  assert.equal(answer, null)
})

test("its settings are shared with the bb side once read, or none when missing", async () => {
  const h = harness()
  const plugin = keyscribe(h.bb, h.host, ["/p/keyscribe.json"])
  assert.equal((await plugin.settings)?.instance, "/Users/me/.bb")
  const missing = harness()
  const none = keyscribe(missing.bb, missing.host, ["/nowhere.json"])
  assert.equal(await none.settings, null)
})

test("at the end of a turn, a hello said again after a failed prompt report follows the reply, never overtakes it", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  await h.answerEvents()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "done" })
  h.open("waiting")[0].answer(0)
  await h.settle()
  assert.equal(h.open("hello").length, 0)
  h.open("turnComplete")[0].answer(200, '{"ok":true}')
  await h.settle()
  const order = h.requests.filter((r) => r.path === "/event" && (r.body.op === "turnComplete" || (r.body.op === "hello" && r.body.session === session("thr_a"))))
  assert.deepEqual(order.slice(-2).map((r) => r.body.op), ["turnComplete", "hello"])
})

test("a hello said again that the app refuses for now is said again once the connection is back", async () => {
  const h = await connected()
  h.interactions.i1 = "pending"
  await h.emit("interaction.pending", { thread: { id: "thr_a" }, interaction: plan })
  h.open("waiting")[0].answer(500)
  await h.settle()
  h.open("hello")[0].answer(500)
  await h.settle()
  const before = h.sent("hello").length
  await h.advance(10_000)
  const again = h.open("hello").find((r) => r.body.session === session("thr_a"))
  assert.ok(h.sent("hello").length > before)
  assert.deepEqual(again?.body.waiting, { kind: "confirm", detail: "p" })
})

test("asked from bb's message box to stop, it tells the app not to read the thread's reply", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  const asked = h.plugin.readAloud("thr_a", false)
  await h.settle()
  const request = h.open("notify")[0]
  assert.deepEqual([request.body.session, request.body.on], [session("thr_a"), false])
  request.answer(200, '{"ok":true,"spoken":true}')
  assert.equal(await asked, true)
})

test("a command in bb's message box answers in the same words as the terminal command", () => {
  assert.equal(commandAnswer("KeyScribe", false, true, true), "KeyScribe will report the result of this work.")
  assert.equal(commandAnswer("KeyScribe", false, true, false), "KeyScribe will report your next reply.")
  assert.equal(commandAnswer("KeyScribe", true, true, true), "KeyScribe won’t report this reply.")
  assert.equal(commandAnswer("KeyScribe", true, false, false), "KeyScribe won’t report this reply.")
  assert.equal(commandAnswer("KeyScribe", false, false, true), "Read Agent Replies Aloud is off. Turn on Read Agent Replies Aloud in KeyScribe’s Agent settings.")
  assert.equal(commandAnswer("KeyScribe", false, "quiet", true), "This conversation is disconnected from KeyScribe. Reconnect it in KeyScribe’s Agent settings.")
  assert.equal(commandAnswer("KeyScribe", false, null, true), "KeyScribe didn’t confirm the request, so you may not get this reply.")
  assert.equal(commandAnswer("KeyScribe", true, null, true), "KeyScribe didn’t confirm the cancel.")
})

test("the command's answer names the app and says whether a turn was running when it was asked", async () => {
  const h = await connected()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  await h.answerEvents()
  const asked = h.plugin.command("thr_a", true)
  await h.settle()
  await h.emit("thread.idle", { thread: { id: "thr_a", status: "idle" }, lastAssistantText: "done" })
  h.open("notify")[0].answer(200, '{"ok":true,"spoken":true}')
  assert.equal(await asked, "KeyScribe will report the result of this work.")
  await h.settle()
  await h.answerEvents()
  assert.equal(h.sent("turnComplete").length, 1)
  const next = h.plugin.command("thr_a", true)
  await h.settle()
  h.open("notify")[0].answer(200, '{"ok":true,"spoken":true}')
  assert.equal(await next, "KeyScribe will report your next reply.")
  assert.equal(await h.plugin.command("thr_c", true), "KeyScribe didn’t confirm the request, so you may not get this reply.")
})

test("a message box shows only the answer to its latest request, whatever order the answers arrive in", () => {
  const answers = new ComposerAnswers()
  const read = answers.begin("c1")
  const cancel = answers.begin("c1")
  assert.equal(answers.settle("c1", cancel, "won’t report"), true)
  assert.equal(answers.settle("c1", read, "will report"), false)
  assert.equal(answers.answer("c1"), "won’t report")
  const other = answers.begin("c2")
  assert.equal(answers.settle("c2", other, "next reply"), true)
  assert.equal(answers.answer("c1"), "won’t report")
  assert.equal(answers.answer("c2"), "next reply")
})

test("a message box remembers answers for only a few message boxes", () => {
  const answers = new ComposerAnswers(2)
  for (const key of ["c1", "c2", "c3"]) answers.settle(key, answers.begin(key), key)
  assert.equal(answers.answer("c1"), undefined)
  assert.equal(answers.answer("c2"), "c2")
  assert.equal(answers.answer("c3"), "c3")
  const late = answers.begin("c2")
  answers.settle("c4", answers.begin("c4"), "c4")
  assert.equal(answers.answer("c3"), undefined)
  assert.equal(answers.settle("c2", late, "again"), true)
})

function composer(
  scope: { kind: string; threadId?: string }, draft: string,
  options: {
    blocked?: boolean; blockedReason?: string; blocksOnSubmit?: boolean; rejects?: string; rejectsFirst?: number; attached?: boolean; emptyReason?: string
  } = {},
) {
  const made = {
    scope,
    text: draft,
    blockedNow: options.blocked ?? false,
    get isSubmittingBlocked() { return made.blockedNow },
    get submittingBlockedReason() {
      if (made.blockedNow) return options.blockedReason ?? null
      return made.text.trim() === "" ? options.emptyReason ?? null : null
    },
    get isEmpty() { return made.text.trim() === "" && !options.attached },
    inserted: [] as Array<{ text: string; at?: string }>,
    submitted: [] as any[],
    onSubmit: undefined as (() => void) | undefined,
    insert(text: string, at?: { at?: "cursor" | "end" }) {
      made.inserted.push({ text, at: at?.at })
      made.text += text
    },
    async submit(how?: any) {
      made.submitted.push(how)
      made.onSubmit?.()
      if (options.blocksOnSubmit) made.blockedNow = true
      const refusing = options.rejectsFirst === undefined || made.submitted.length <= options.rejectsFirst
      if (options.rejects && refusing) throw new Error(options.rejects)
    },
  }
  return made
}

test("a dictation joins the draft at its end and is sent the way Enter steers a running turn", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "half a thought")
  assert.deepEqual(await composeInto([box], "thr_a", "run the tests"), { outcome: "sent", joined: "half a thought run the tests" })
  assert.deepEqual(box.inserted, [{ text: " run the tests", at: "end" }])
  assert.deepEqual(box.submitted, [{ experimental_mode: "steer-if-active" }])
})

test("a draft that already ends in a new line takes the dictation with no extra space", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "first line\n")
  assert.deepEqual(await composeInto([box], "thr_a", "run the tests"), { outcome: "sent", joined: "first line\nrun the tests" })
})

test("an empty message box, or none for the thread, is left alone so the dictation goes the usual way", async () => {
  const empty = composer({ kind: "thread", threadId: "thr_a" }, "  ")
  const other = composer({ kind: "thread", threadId: "thr_b" }, "their draft")
  const fresh = composer({ kind: "new-thread" }, "a new idea")
  assert.deepEqual(await composeInto([empty, other, fresh], "thr_a", "x"), { outcome: "empty" })
  assert.deepEqual(await composeInto([other, fresh], "thr_a", "x"), { outcome: "empty" })
  for (const box of [empty, other, fresh]) assert.deepEqual(box.inserted, [])
})

test("a draft bb would not send now, or two boxes for one thread, are never touched", async () => {
  const blocked = composer({ kind: "thread", threadId: "thr_a" }, "half", { blocked: true })
  assert.deepEqual(await composeInto([blocked], "thr_a", "x"), { outcome: "blocked" })
  const one = composer({ kind: "thread", threadId: "thr_a" }, "half")
  const two = composer({ kind: "thread", threadId: "thr_a" }, "half")
  assert.deepEqual(await composeInto([one, two], "thr_a", "x"), { outcome: "blocked" })
  for (const box of [blocked, one, two]) assert.deepEqual(box.inserted, [])
})

test("a joined draft bb fails to send once it took the send is unclear, never sent again, and stays in the box", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "half", { rejects: "The request failed" })
  assert.deepEqual(await composeInto([box], "thr_a", "run the tests"), { outcome: "unclear", why: "The request failed (after bb showed the words)" })
  assert.equal(box.submitted.length, 1)
  assert.equal(box.text, "half run the tests")
})

async function shownIn(h: Awaited<ReturnType<typeof connected>>, thread: string) {
  h.plugin.window({ window: "w1", focused: true, thread })
  await h.settle()
  await answerShown(h)
}

function mergeCommand(h: Awaited<ReturnType<typeof connected>>, thread = "thr_a") {
  h.open("poll")[0].answer(200, JSON.stringify({
    commands: [{ op: "submit", id: "j1", expectedSession: session(thread), text: "run the tests", expiresAt: 9e15, merge: true }], unknown: [],
  }))
  return h.settle()
}

const answersFor = (h: Awaited<ReturnType<typeof connected>>, request: string) =>
  h.requests.filter((r) => r.path === "/event" && r.body.request === request).map((r) => r.body.reason ?? r.body.op)

test("a dictation for the thread a window shows is joined there by that window, and said sent", async () => {
  const h = await connected()
  await shownIn(h, "thr_a")
  await mergeCommand(h)
  assert.deepEqual(h.composes, [{ window: "w1", thread: "thr_a", text: "run the tests" }])
  assert.deepEqual(answersFor(h, "j1"), ["ack", "submitted"])
})

for (const [outcome, reason] of [["empty", "empty"], ["blocked", "draft"], ["failed", "added"], ["unclear", "unclear"]] as const) {
  test(`a window that answers ${outcome} is reported as ${reason}`, async () => {
    const h = await connected()
    await shownIn(h, "thr_a")
    h.composing.answer = { outcome }
    await mergeCommand(h)
    assert.deepEqual(answersFor(h, "j1"), ["ack", reason])
  })
}

test("a window that never answers leaves the dictation unanswered rather than guessed", async () => {
  const h = await connected()
  await shownIn(h, "thr_a")
  h.composing.answer = null
  await mergeCommand(h)
  assert.deepEqual(answersFor(h, "j1"), ["ack"])
})

test("a dictation for a thread no window shows is never joined there", async () => {
  const h = await connected()
  await shownIn(h, "thr_b")
  await mergeCommand(h)
  assert.deepEqual(h.composes, [])
  assert.deepEqual(answersFor(h, "j1"), ["ack", "empty"])
})

test("the turn a joined message starts is named by the dictation it carried", async () => {
  const h = await connected({ history: { thr_a: ["half a thought run the tests"] } })
  await shownIn(h, "thr_a")
  await mergeCommand(h)
  await h.answerEvents()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  assert.equal(h.sent("turnStarted")[0].prompt, promptDigest("run the tests"))
})

test("two empty message boxes for one thread are an empty box, not a draft", async () => {
  const one = composer({ kind: "thread", threadId: "thr_a" }, "")
  const two = composer({ kind: "thread", threadId: "thr_a" }, " ")
  assert.deepEqual(await composeInto([one, two], "thr_a", "x"), { outcome: "empty" })
})

test("a draft that would run as a command is never joined, so bb's send never runs it with the dictation", async () => {
  for (const draft of ["/model", "  !ls"]) {
    const box = composer({ kind: "thread", threadId: "thr_a" }, draft)
    assert.deepEqual(await composeInto([box], "thr_a", "x"), { outcome: "blocked" })
    assert.deepEqual(box.inserted, [])
  }
})

test("a draft that ends in a tab takes the dictation with no extra space", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "first\t")
  assert.deepEqual(await composeInto([box], "thr_a", "run the tests"), { outcome: "sent", joined: "first\trun the tests" })
})

test("a dictation that would run as a command is never joined to a draft and never reaches a window", async () => {
  const h = await connected()
  await shownIn(h, "thr_a")
  h.open("poll")[0].answer(200, JSON.stringify({
    commands: [{ op: "submit", id: "j1", expectedSession: session("thr_a"), text: "  /compact", expiresAt: 9e15, merge: true }], unknown: [],
  }))
  await h.settle()
  assert.deepEqual(h.composes, [])
  assert.deepEqual(answersFor(h, "j1"), ["ack", "draft"])
})

test("the thread in front is said to have text in its message box as soon as the window reports it, and again when it is gone", async () => {
  const h = await connected()
  await shownIn(h, "thr_a")
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a", draft: true })
  await h.settle()
  await answerShown(h)
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a", draft: false })
  await h.settle()
  await answerShown(h)
  assert.deepEqual(h.sent("shown").slice(1).map((b) => [b.session, b.on, b.draft]),
    [[session("thr_a"), true, false], [session("thr_a"), true, true], [session("thr_a"), true, false]])
})

test("the turn a joined message starts is named by the dictation even when bb keeps the message without its trailing space", async () => {
  const h = await connected({ history: { thr_a: ["half a thought run the tests"] } })
  h.composing.answer = { outcome: "sent", joined: "half a thought run the tests " }
  await shownIn(h, "thr_a")
  await mergeCommand(h)
  await h.answerEvents()
  await h.emit("thread.active", { thread: { id: "thr_a", status: "active" } })
  assert.equal(h.sent("turnStarted")[0].prompt, promptDigest("run the tests"))
})

test("a message box holding only an attachment takes the dictation with no space before it", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "", { attached: true })
  assert.deepEqual(await composeInto([box], "thr_a", "what is this"), { outcome: "sent", joined: "what is this" })
  assert.deepEqual(box.inserted, [{ text: "what is this", at: "end" }])
})

test("a dictation for a new thread is typed into the empty new-thread box and sent the way Enter sends it", async () => {
  const fresh = composer({ kind: "new-thread" }, "")
  const other = composer({ kind: "thread", threadId: "thr_a" }, "their draft")
  assert.deepEqual(await composeInto([other, fresh], null, "plan the release"), { outcome: "sent", joined: "plan the release" })
  assert.deepEqual(fresh.inserted, [{ text: "plan the release", at: "end" }])
  assert.deepEqual(fresh.submitted, [undefined])
  assert.deepEqual(other.inserted, [])
})

test("a dictation for a new thread is sent only once bb shows it in the box, since bb sends what it has registered", async () => {
  let live = ""
  let drawn = ""
  const snapshot = () => {
    const blocked = drawn.trim() === ""
    return {
      scope: { kind: "new-thread" },
      get text() { return live },
      get isEmpty() { return live.trim() === "" },
      isSubmittingBlocked: blocked,
      insert(more: string) {
        live += more
        setTimeout(() => { drawn = live }, 5)
      },
      async submit() { if (blocked) throw new Error("Enter a prompt or attach a file.") },
    }
  }
  assert.deepEqual(await composeInto([snapshot()], null, "plan the release", () => [snapshot()]), { outcome: "sent", joined: "plan the release" })
})

test("a new thread bb refuses as empty while it catches up with the words is sent again until bb takes them", async () => {
  const box = composer({ kind: "new-thread" }, "", { rejectsFirst: 3, rejects: "Enter a prompt or attach a file." })
  assert.deepEqual(await composeInto([box], null, "plan the release"), { outcome: "sent", joined: "plan the release" })
  assert.equal(box.submitted.length, 4)
  assert.deepEqual(box.inserted, [{ text: "plan the release", at: "end" }])
})

test("a refusal bb keeps giving ends within a bounded wait with bb's words, and the dictation is typed only once", async () => {
  const box = composer({ kind: "new-thread" }, "", { rejects: "Enter a prompt or attach a file." })
  const started = Date.now()
  assert.deepEqual(await composeInto([box], null, "plan the release"), {
    outcome: "failed", alone: true, why: "Enter a prompt or attach a file. (after bb showed the words)", said: "Enter a prompt or attach a file.",
  })
  assert.ok(Date.now() - started < 3000)
  assert.ok(box.submitted.length > 1)
  assert.equal(box.text, "plan the release")
})

test("a refusal from a box bb says cannot send is reported at once, never sent again", async () => {
  const box = composer({ kind: "new-thread" }, "", { blocked: true, blockedReason: "Pick a project first", rejects: "Pick a project first" })
  const answer = await composeInto([box], null, "plan the release")
  assert.equal(answer.outcome, "failed")
  assert.equal(box.submitted.length, 1)
})

test("bb's refusal of a box it has not caught up with is recognized by the reason bb gave for the box while empty, however bb words it", async () => {
  const box = composer({ kind: "new-thread" }, "", { rejectsFirst: 2, rejects: "Écrivez un message.", emptyReason: "Écrivez un message." })
  assert.deepEqual(await composeInto([box], null, "plan the release"), { outcome: "sent", joined: "plan the release" })
  assert.equal(box.submitted.length, 3)
})

test("bb's other refusal of an empty draft is also retried", async () => {
  const box = composer({ kind: "new-thread" }, "", { rejectsFirst: 1, rejects: "Type a message first." })
  assert.deepEqual(await composeInto([box], null, "plan the release"), { outcome: "sent", joined: "plan the release" })
  assert.equal(box.submitted.length, 2)
})

test("an error bb gives for a send it may have taken stays unclear, even when the box is blocked afterwards", async () => {
  const box = composer({ kind: "new-thread" }, "", { blocksOnSubmit: true, blockedReason: "A turn is starting", rejects: "socket hang up" })
  assert.deepEqual(await composeInto([box], null, "plan the release"), { outcome: "unclear", why: "socket hang up (after bb showed the words)" })
  assert.equal(box.submitted.length, 1)
})

test("an error that is not the reason bb gave for a blocked box stays unclear", async () => {
  const late = composer({ kind: "new-thread" }, "", { blocked: true, blockedReason: "Pick a project first", rejects: "socket hang up" })
  assert.equal((await composeInto([late], null, "plan the release")).outcome, "unclear")
})

test("a dictation joined to a thread's draft that bb refuses while catching up is sent again until bb takes it", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "half", { rejectsFirst: 2, rejects: "Enter a prompt or attach a file." })
  assert.deepEqual(await composeInto([box], "thr_a", "run the tests"), { outcome: "sent", joined: "half run the tests" })
  assert.equal(box.submitted.length, 3)
  assert.ok(box.submitted.every((how) => how?.experimental_mode === "steer-if-active"))
})

test("a send bb refused is never tried again once the box holds anything but the dictation", async () => {
  const box = composer({ kind: "new-thread" }, "", { rejects: "Enter a prompt or attach a file." })
  box.onSubmit = () => { box.text += " and more" }
  const answer = await composeInto([box], null, "plan the release")
  assert.equal(answer.outcome, "failed")
  assert.equal(box.submitted.length, 1)
})

test("a dictation joined to a box that can already send is sent at once, whatever bb makes of its text", async () => {
  const box = composer({ kind: "thread", threadId: "thr_a" }, "half")
  Object.defineProperty(box, "text", { get: () => "half", set: () => {} })
  let looked = 0
  assert.deepEqual(await composeInto([box], "thr_a", "run the tests", () => { looked += 1; return [box] }), { outcome: "sent", joined: "half run the tests" })
  assert.equal(looked, 0)
})

test("a dictation for a new thread joins what the user already typed there", async () => {
  const fresh = composer({ kind: "new-thread" }, "about the docs")
  assert.deepEqual(await composeInto([fresh], null, "plan the release"), { outcome: "sent", joined: "about the docs plan the release" })
})

test("with no new-thread box on screen nothing goes in, and two of them, or a draft that runs as a command, are never touched", async () => {
  const thread = composer({ kind: "thread", threadId: "thr_a" }, "")
  assert.deepEqual(await composeInto([thread], null, "x"), { outcome: "empty" })
  const one = composer({ kind: "new-thread" }, "")
  const two = composer({ kind: "new-thread" }, "")
  assert.deepEqual(await composeInto([one, two], null, "x"), { outcome: "blocked" })
  const command = composer({ kind: "new-thread" }, "/model")
  assert.deepEqual(await composeInto([command], null, "x"), { outcome: "blocked" })
  for (const box of [thread, one, two, command]) assert.deepEqual(box.inserted, [])
})

test("a new thread bb would not start leaves the dictation alone in its box, and says so", async () => {
  const empty = composer({ kind: "new-thread" }, "", { blocked: true, blockedReason: "Pick a project first", rejects: "Pick a project first" })
  assert.deepEqual(await composeInto([empty], null, "plan the release"), { outcome: "failed", alone: true, why: "Pick a project first (after bb showed the words)", said: "Pick a project first" })
  assert.equal(empty.text, "plan the release")
  const drafted = composer({ kind: "new-thread" }, "half", { rejects: "The request failed" })
  assert.deepEqual(await composeInto([drafted], null, "plan"), { outcome: "unclear", why: "The request failed (after bb showed the words)" })
  assert.equal(drafted.submitted.length, 1)
})

test("a new thread bb would not start is refused with bb's own words for why, and without them when bb gave none", async () => {
  const refusal = (h: Awaited<ReturnType<typeof connected>>) => h.requests.find((r) => r.body.request === "s1" && r.body.op === "refused")!.body
  const h = await connected()
  await onNewThreadPage(h)
  h.composing.answer = { outcome: "failed", alone: true, why: "Enter a prompt or attach a file. (after bb showed the words)", said: "Enter a prompt or attach a file." }
  await startCommand(h)
  assert.equal(refusal(h).reason, "filled")
  assert.equal(refusal(h).detail, "Enter a prompt or attach a file.")
  const g = await connected()
  await onNewThreadPage(g)
  g.composing.answer = { outcome: "failed", alone: true }
  await startCommand(g)
  assert.equal(refusal(g).detail, undefined)
})

const startEvents = (h: { sent: (op: string) => any[] }) => h.sent("shown").slice(1).map((b) => [b.on, b.newConversation === true])

test("a window on bb's new-thread page is reported as showing a box that starts a conversation, and no longer once a thread is shown", async () => {
  const h = await connected()
  h.plugin.window({ window: "w1", focused: true, thread: null, newThread: true })
  await h.settle()
  await answerShown(h)
  h.plugin.window({ window: "w1", focused: true, thread: "thr_a", newThread: false })
  await h.settle()
  await answerShown(h)
  h.plugin.window({ window: "w1", focused: true, thread: null, newThread: false })
  await h.settle()
  await answerShown(h)
  assert.deepEqual(startEvents(h), [[false, true], [true, false], [false, false]])
})

test("a plugin that starts conversations says so on its hello", async () => {
  const h = await connected()
  assert.ok(h.sent("hello")[0].features.includes("start"))
})

function startCommand(h: Awaited<ReturnType<typeof connected>>, text = "plan the release", through = session("thr_a")) {
  h.open("poll")[0].answer(200, JSON.stringify({
    commands: [{ op: "start", id: "s1", expectedSession: through, text, expiresAt: 9e15 }], unknown: [],
  }))
  return h.settle()
}

const starter = session("new conversation")

test("with no threads yet it still says hello, under the key for a new conversation, and says when the new-thread page is in front", async () => {
  const h = await connected({ threads: [] })
  const hello = h.sent("hello").find((b) => b.session === starter)
  assert.ok(hello)
  assert.equal(hello.idle, true)
  assert.ok(hello.features.includes("start"))
  assert.ok(h.open("poll")[0].body.members.some((m: any) => m.session === starter))
  await onNewThreadPage(h)
  const shown = h.sent("shown").at(-1)
  assert.equal(shown.session, starter)
  assert.equal(shown.on, false)
  assert.equal(shown.newConversation, true)
})

test("with no threads yet a dictation for a new conversation is sent from the new-thread box, and the thread it starts says hello", async () => {
  const h = await connected({ threads: [] })
  await onNewThreadPage(h)
  h.composing.answer = { outcome: "sent", joined: "plan the release" }
  await startCommand(h, "plan the release", starter)
  assert.deepEqual(h.composes, [{ window: "w1", thread: null, text: "plan the release" }])
  assert.deepEqual(answersFor(h, "s1"), ["ack", "submitted"])
  await h.emit("thread.created", { thread: { id: "thr_new", status: "active" } })
  assert.ok(h.sent("hello").some((b) => b.session === session("thr_new")))
})

async function onNewThreadPage(h: Awaited<ReturnType<typeof connected>>) {
  h.plugin.window({ window: "w1", focused: true, thread: null, newThread: true })
  await h.settle()
  await answerShown(h)
}

test("a dictation for a new conversation is sent from the new-thread box of the window in front, and said sent", async () => {
  const h = await connected()
  await onNewThreadPage(h)
  h.composing.answer = { outcome: "sent", joined: "plan the release" }
  await startCommand(h)
  assert.deepEqual(h.composes, [{ window: "w1", thread: null, text: "plan the release" }])
  assert.deepEqual(answersFor(h, "s1"), ["ack", "submitted"])
  assert.equal(h.requests.find((r) => r.body.request === "s1" && r.body.op === "submitted")!.body.withDraft, undefined)
})

test("a dictation joined to text already in the new-thread box is said sent with it", async () => {
  const h = await connected()
  await onNewThreadPage(h)
  h.composing.answer = { outcome: "sent", joined: "about the docs plan the release" }
  await startCommand(h)
  assert.equal(h.requests.find((r) => r.body.request === "s1" && r.body.op === "submitted")!.body.withDraft, true)
})

test("a dictation for a new conversation is never sent once the window in front no longer shows the new-thread page", async () => {
  const h = await connected()
  await shownIn(h, "thr_b")
  await startCommand(h)
  assert.deepEqual(h.composes, [])
  assert.deepEqual(answersFor(h, "s1"), ["ack", "gone"])
})

for (const [answer, reason] of [
  [{ outcome: "empty" }, "gone"], [{ outcome: "blocked" }, "draft"], [{ outcome: "failed" }, "added"], [{ outcome: "failed", alone: true }, "filled"],
  [{ outcome: "unclear" }, "unclear"],
] as const) {
  test(`a new-thread window that answers ${JSON.stringify(answer)} is reported as ${reason}`, async () => {
    const h = await connected()
    await onNewThreadPage(h)
    h.composing.answer = answer as Composed
    await startCommand(h)
    assert.deepEqual(answersFor(h, "s1"), ["ack", reason])
  })
}

test("a dictation that would run as a command never starts a conversation", async () => {
  const h = await connected()
  await onNewThreadPage(h)
  await startCommand(h, " /compact")
  assert.deepEqual(h.composes, [])
  assert.deepEqual(answersFor(h, "s1"), ["ack", "command"])
})

test("the first turn of the thread a dictation started is named by that dictation, even when it starts before the thread's hello lands", async () => {
  const h = await connected({ history: { thr_new: ["about the docs plan the release"] } })
  await onNewThreadPage(h)
  h.composing.answer = { outcome: "sent", joined: "about the docs plan the release" }
  await startCommand(h)
  await h.answerEvents()
  await h.emit("thread.created", { thread: { id: "thr_new", status: "idle" } })
  await h.emit("thread.active", { thread: { id: "thr_new", status: "active" } })
  assert.equal(h.sent("turnStarted").length, 0)
  await h.answerHellos()
  await h.answerEvents()
  const started = h.sent("turnStarted").filter((b) => b.session === session("thr_new"))
  assert.equal(started.length, 1)
  assert.equal(started[0].prompt, promptDigest("plan the release"))
})

test("a turn that started and ended before its thread's hello landed is never reported", async () => {
  const h = await connected()
  await h.emit("thread.created", { thread: { id: "thr_new", status: "idle" } })
  await h.emit("thread.active", { thread: { id: "thr_new", status: "active" } })
  await h.emit("thread.idle", { thread: { id: "thr_new", status: "idle" }, lastAssistantText: "done" })
  await h.answerHellos()
  await h.answerEvents()
  assert.equal(h.sent("turnStarted").filter((b) => b.session === session("thr_new")).length, 0)
})

test("a reply names a thread it mentions by the name the app gave it, never by its id", () => {
  const names = new Map([["thr_known", "docs green"]])
  const nameOf = (thread: string) => names.get(thread) ?? null
  assert.equal(spokenMentions("See @thread:thr_known for the plan.", nameOf), "See docs green for the plan.")
  assert.equal(spokenMentions("Started @thread:thr_01HX9ZQ, and asked @thread:thr_known#msg=42.", nameOf), "Started another thread, and asked docs green.")
  assert.equal(spokenMentions("Mail me@thread:x and keep thread:thr_a", nameOf), "Mail me@thread:x and keep thread:thr_a")
})
