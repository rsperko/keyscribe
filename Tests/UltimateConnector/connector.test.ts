import assert from "node:assert/strict"
import { test } from "node:test"
import { focusConnectionContract } from "../AgentConformance/lib/focus-contract.ts"
import {
  joined, keyscribe, namedByUser, promptDigest, readAloudReply, readAloudToolName, waitingFor,
  type Host, type Image, type Summary, type Ultimate,
} from "../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts"

type Request = { path: string; body: any; answer: (status: number, text?: string) => void; settled: boolean }
const home = "/u/.ultimate/projects/app-1234"
const session = (id: number) => `${id}@${home}`

function harness(options: { conversations?: Summary[]; ready?: boolean; holdShown?: boolean; submit?: (id: number, text: string, images: Image[], requestId: string) => Promise<number> } = {}) {
  const requests: Request[] = []
  const timers: Array<{ at: number; fn: () => void; id: number }> = []
  const logs: string[] = []
  const submitted: Array<{ id: number; text: string; images: Image[]; requestId: string }> = []
  let timerId = 0
  let now = 1_000_000
  let submissions = 100
  const config = {
    protocol: 3, socketPath: "/s/bridge.sock", tokenPath: "/s/token", readyPath: "/s/ready.json", installation: "I1",
    setup: "/u/.ultimate", version: "1", appName: "KeyScribe", plugin: "keyscribe",
  }
  const files: Record<string, string | undefined> = {
    "/s/token": "secret\n",
    "/s/ready.json": options.ready === false ? undefined : JSON.stringify({ launch: "L1", protocol: 3 }),
    "/tmp/shot.png": "PNGDATA",
  }
  const state = {
    conversations: options.conversations ?? [
      { id: 53, title: "@ultimate", named: true, cwd: "/w/app", busy: false },
      { id: 61, title: "Fix the login", named: false, cwd: "/h/wt/61", busy: false },
    ] as Summary[],
  }
  const ultimate: Ultimate = {
    version: "",
    home,
    list: () => state.conversations,
    submit: options.submit ?? (async (id, text, images, requestId) => {
      submitted.push({ id, text, images, requestId })
      return ++submissions
    }),
  }
  const host: Host = {
    pid: 4242,
    now: () => now,
    read: async (path) => {
      const text = files[path]
      if (text === undefined) throw new Error("ENOENT")
      return text
    },
    readBase64: async (path) => {
      const text = files[path]
      if (text === undefined) throw new Error("ENOENT")
      return Buffer.from(text).toString("base64")
    },
    after: (ms, fn) => {
      const id = ++timerId
      timers.push({ at: now + ms, fn, id })
      return () => {
        const index = timers.findIndex((t) => t.id === id)
        if (index >= 0) timers.splice(index, 1)
      }
    },
    post: (_socket, path, body) => {
      let resolve: (r: { status: number; ok: boolean; text: string }) => void = () => {}
      const response = new Promise<{ status: number; ok: boolean; text: string }>((r) => { resolve = r })
      const request: Request = {
        path, body: JSON.parse(body), settled: false,
        answer: (status, text = "") => {
          if (request.settled) return
          request.settled = true
          resolve({ status, ok: status >= 200 && status < 300, text })
        },
      }
      requests.push(request)
      if (path === "/event" && request.body.op !== "hello" && request.body.op !== "notify" && !(options.holdShown && request.body.op === "shown")) request.answer(200, "{}")
      return { response, cancel: () => request.answer(0) }
    },
    random: () => "rnd",
    log: (message) => { logs.push(message) },
  }
  const connector = keyscribe(ultimate, host, async () => config)
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
  async function flush() {
    for (let i = 0; i < 12; i++) await settle()
  }
  async function connect() {
    await flush()
    for (const r of requests.filter((r) => r.body.op === "hello" && !r.settled)) r.answer(200, "{}")
    await flush()
  }
  const events = (op: string) => requests.filter((r) => r.path === "/event" && r.body.op === op).map((r) => r.body)
  const poll = () => requests.filter((r) => r.path === "/poll" && !r.settled).at(-1)
  async function command(body: object) {
    const p = poll()
    assert.ok(p, "the connector is polling")
    p.answer(200, JSON.stringify([body]))
    await flush()
  }
  return {
    connector, state, requests, submitted, logs, events, poll, command, flush, connect,
    advance: async (ms: number) => {
      now += ms
      for (const timer of [...timers].sort((a, b) => a.at - b.at)) {
        if (timer.at > now) continue
        timers.splice(timers.indexOf(timer), 1)
        timer.fn()
      }
      await flush()
    },
    get now() { return now },
  }
}

focusConnectionContract("Ultimate", async () => {
  const h = harness({ holdShown: true })
  await h.flush()
  return {
    focus: async focused => { h.connector.page({ page: "p1", focused, conversation: 61, draft: false }); await h.flush() },
    connect: h.connect,
    drain: async () => {
      for (let i = 0; i < 4; i++) {
        for (const request of h.requests.filter(r => r.body.op === "shown" && !r.settled)) request.answer(200, "{}")
        await h.flush()
      }
    },
    reports: () => h.events("shown"),
    stop: h.connector.stop,
  }
})

test("each conversation Ultimate lists says hello under its project home, with only a name the user gave", async () => {
  const h = harness()
  await h.connect()
  const hellos = h.events("hello")
  assert.deepEqual(hellos.map((hello) => hello.session).sort(), [session(53), session(61)])
  const ultimate = hellos.find((hello) => hello.session === session(53))
  const branch = hellos.find((hello) => hello.session === session(61))
  assert.equal(ultimate.title, "@ultimate")
  assert.equal(branch.title, undefined)
  assert.equal(ultimate.agent, "ultimate")
  assert.equal(ultimate.installation, "I1")
  assert.ok(ultimate.features.includes("steer"))
  assert.ok(ultimate.features.includes("merge"))
  assert.equal(ultimate.idle, true)
  assert.ok(h.poll())
  assert.deepEqual(h.poll()!.body.members.map((m: any) => m.session).sort(), [session(53), session(61)])
})

test("a conversation that is working when the app connects says so with its turn", async () => {
  const h = harness({ conversations: [{ id: 53, title: "@ultimate", named: true, cwd: "/w", busy: true }] })
  await h.connect()
  const [hello] = h.events("hello")
  assert.equal(hello.idle, false)
  assert.equal(typeof hello.turn, "string")
})

test("while the app is not running the connector sends nothing and checks again later", async () => {
  const h = harness({ ready: false })
  await h.flush()
  assert.equal(h.requests.length, 0)
  assert.ok(h.logs.some((log) => log.includes("not running")))
})

test("a turn reports its start, what it came after, and its final reply", async () => {
  const h = harness()
  await h.connect()
  h.state.conversations[1].busy = true
  h.connector.changed()
  await h.flush()
  const [started] = h.events("turnStarted")
  assert.equal(started.session, session(61))
  h.connector.input(61, 900, "pi.user", "run the tests")
  h.connector.replied(61, "Running them now.", "toolUse")
  h.connector.replied(61, "All 12 tests pass.", "stop")
  h.state.conversations[1].busy = false
  h.connector.changed()
  await h.flush()
  const [complete] = h.events("turnComplete")
  assert.equal(complete.reason, "complete")
  assert.equal(complete.answer, "All 12 tests pass.")
  assert.equal(complete.prompt, promptDigest("run the tests"))
  assert.equal(complete.from, undefined)
  assert.equal(complete.turn, undefined)
})

test("a message that arrives once the agent has answered starts a turn of its own, so the answer is reported at once", async () => {
  const h = harness()
  await h.connect()
  h.connector.input(61, 910, "pi.user", "Yes to all four.")
  h.connector.replied(61, "Starting on them.", "toolUse")
  h.connector.replied(61, "All four are in.", "stop")
  await h.flush()
  assert.deepEqual(h.events("turnComplete").map((c) => [c.answer, c.prompt, c.from]), [])
  h.connector.input(61, 911, "board.delivered", "Message from @ultimate")
  await h.flush()
  assert.deepEqual(h.events("turnComplete").map((c) => [c.answer, c.prompt, c.from]), [["All four are in.", promptDigest("Yes to all four."), undefined]])
  h.connector.replied(61, "As I said, the disk writer is an update.", "stop")
  h.state.conversations[1].busy = true
  h.connector.changed()
  h.state.conversations[1].busy = false
  h.connector.changed()
  await h.flush()
  assert.deepEqual(h.events("turnComplete").map((c) => [c.answer, c.from]), [["All four are in.", undefined], ["As I said, the disk writer is an update.", "agent"]])
  assert.equal(h.events("turnStarted").length, 2)
})

test("a message that arrives while the agent is still working, or after a failed reply, stays in the turn", async () => {
  for (const [said, stop] of [["Looking.", "toolUse"], ["partial", "error"]]) {
    const h = harness()
    await h.connect()
    h.connector.input(61, 920, "pi.user", "check the build")
    h.connector.replied(61, said, stop)
    h.connector.input(61, 921, "board.delivered", "Message from @ultimate")
    h.connector.replied(61, "Both done.", "stop")
    h.state.conversations[1].busy = true
    h.connector.changed()
    h.state.conversations[1].busy = false
    h.connector.changed()
    await h.flush()
    assert.equal(h.events("turnStarted").length, 1, stop)
    assert.deepEqual(h.events("turnComplete").map((c) => [c.answer, c.from]), [["Both done.", "agent"]], stop)
  }
})

test("a turn another agent started says so, and a failed turn reports no reply", async () => {
  const h = harness()
  await h.connect()
  h.connector.input(61, 901, "board.delivered", "Message from @ultimate")
  h.connector.replied(61, "partial", "error")
  h.state.conversations[1].busy = true
  h.connector.changed()
  h.state.conversations[1].busy = false
  h.connector.changed()
  await h.flush()
  const [complete] = h.events("turnComplete")
  assert.equal(complete.reason, "error")
  assert.equal(complete.answer, "")
  assert.equal(complete.from, "agent")
})

test("an idle dictation is submitted as the user's message and confirmed once Ultimate places it, in either order", async () => {
  for (const placedFirst of [true, false]) {
    const h = harness()
    await h.connect()
    await h.command({ op: "submit", id: "req-1", expectedSession: session(61), text: "fix the login redirect", expiresAt: h.now + 10_000 })
    assert.deepEqual(h.submitted.map((s) => [s.id, s.text, s.requestId]), [[61, "fix the login redirect", "req-1"]])
    assert.equal(h.events("submitted").length, 0)
    if (placedFirst) h.connector.placed(101, 7000)
    h.connector.input(61, 7000, "pi.user", "fix the login redirect")
    if (!placedFirst) h.connector.placed(101, 7000)
    await h.flush()
    const [receipt] = h.events("submitted")
    assert.equal(receipt.request, "req-1")
    assert.ok(receipt.turn, "the receipt names the turn the dictation started")
    assert.equal(h.events("turnStarted")[0].turn, receipt.turn)
  }
})

test("a dictation Ultimate places before its submit call returns is still confirmed", async () => {
  let release: (n: number) => void = () => {}
  const h = harness({ submit: () => new Promise<number>((resolve) => { release = resolve }) })
  await h.connect()
  await h.command({ op: "submit", id: "req-2", expectedSession: session(61), text: "hello", expiresAt: h.now + 10_000 })
  h.connector.placed(555, 8000)
  h.connector.input(61, 8000, "pi.user", "hello")
  release(555)
  await h.flush()
  assert.equal(h.events("submitted")[0]?.request, "req-2")
})

test("a dictation for a working conversation is confirmed when queued and reported absorbed when the turn takes it", async () => {
  const h = harness()
  await h.connect()
  h.state.conversations[0].busy = true
  h.connector.changed()
  await h.flush()
  const turn = h.events("turnStarted")[0].turn
  await h.command({ op: "submit", id: "req-3", expectedSession: session(53), text: "also check the docs", expiresAt: h.now + 10_000 })
  const [receipt] = h.events("submitted")
  assert.equal(receipt.request, "req-3")
  assert.equal(receipt.turn, "")
  h.connector.placed(101, 9000)
  h.connector.input(53, 9000, "pi.user", "also check the docs")
  await h.flush()
  const [absorbed] = h.events("absorbed")
  assert.equal(absorbed.turn, turn)
  assert.equal(absorbed.prompt, promptDigest("also check the docs"))
  assert.equal(absorbed.request, "req-3")
  assert.equal(h.events("submitted").length, 1)
})

test("an expired, disconnected or refused dictation is refused and never submitted twice", async () => {
  const h = harness({ submit: async () => { throw new Error("Conversation is concluded") } })
  await h.connect()
  await h.command({ op: "submit", id: "late", expectedSession: session(61), text: "x", expiresAt: h.now - 1 })
  await h.command({ op: "submit", id: "bad", expectedSession: session(61), text: "x", expiresAt: h.now + 10_000 })
  await h.command({ op: "quiet", id: "q", expectedSession: session(61) })
  await h.command({ op: "submit", id: "quiet", expectedSession: session(61), text: "x", expiresAt: h.now + 10_000 })
  const refused = Object.fromEntries(h.events("refused").map((r) => [r.request, r.reason]))
  assert.equal(refused.late, "expired")
  assert.equal(refused.bad, "Conversation is concluded")
  assert.equal(refused.quiet, "disconnected")
})

test("a disconnected conversation reports nothing about its turns", async () => {
  const h = harness()
  await h.connect()
  await h.command({ op: "quiet", id: "q", expectedSession: session(61) })
  h.state.conversations[1].busy = true
  h.connector.changed()
  h.state.conversations[1].busy = false
  h.connector.changed()
  await h.flush()
  assert.equal(h.events("turnStarted").length, 0)
  assert.equal(h.events("turnComplete").length, 0)
})

test("a check answers what became of a dictation", async () => {
  const h = harness()
  await h.connect()
  await h.command({ op: "submit", id: "req-4", expectedSession: session(61), text: "x", expiresAt: h.now + 10_000 })
  await h.command({ op: "check", id: "c1", expectedSession: session(61), request: "req-4", expiresAt: h.now + 1000 })
  await h.command({ op: "check", id: "c2", expectedSession: session(61), request: "never", expiresAt: h.now + 1000 })
  const checked = Object.fromEntries(h.events("checked").map((c) => [c.check, c.state]))
  assert.equal(checked.c1, "handed")
  assert.equal(checked.c2, "unknown")
})

test("a PNG attached to a dictation travels with it", async () => {
  const h = harness()
  await h.connect()
  await h.command({ op: "submit", id: "img", expectedSession: session(61), text: "look", images: ["/tmp/shot.png", "/tmp/missing.png", "/tmp/x.jpg"], expiresAt: h.now + 10_000 })
  assert.deepEqual(h.submitted[0].images, [{ data: Buffer.from("PNGDATA").toString("base64"), mimeType: "image/png" }])
})

test("the focused page tells the app which conversation is in front and whether its box has text", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 61, draft: true })
  await h.flush()
  const shown = h.events("shown").at(-1)
  assert.deepEqual([shown.session, shown.on, shown.draft], [session(61), true, true])
  h.connector.page({ page: "p1", focused: false, conversation: 61, draft: true })
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, false)
})

test("a page that stops reporting no longer counts as in front", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 61, draft: false })
  await h.flush()
  await h.advance(20_000)
  assert.equal(h.events("shown").at(-1).on, false)
})

test("a dictation for the conversation in front joins the draft in its box and sends them together", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 61, draft: true })
  const next = h.connector.nextCompose("p1")
  await h.command({ op: "submit", id: "m1", expectedSession: session(61), text: "and the logout too", merge: true, expiresAt: h.now + 10_000 })
  const ask = await next
  assert.deepEqual(ask, { id: "m1", conversation: 61, text: "and the logout too" })
  const sent = h.connector.composed("m1", "p1", "fix the login")
  await h.flush()
  assert.equal(await sent, true)
  assert.equal(h.submitted[0].text, "fix the login and the logout too")
  h.connector.placed(101, 7100)
  h.connector.input(61, 7100, "pi.user", "fix the login and the logout too")
  await h.flush()
  const [receipt] = h.events("submitted")
  assert.equal(receipt.withDraft, true)
  h.state.conversations[1].busy = true
  h.connector.changed()
  h.state.conversations[1].busy = false
  h.connector.changed()
  await h.flush()
  assert.equal(h.events("turnComplete")[0].prompt, promptDigest("and the logout too"))
})

test("with no page to join, or an empty draft, the dictation goes alone", async () => {
  const h = harness()
  await h.connect()
  await h.command({ op: "submit", id: "m2", expectedSession: session(61), text: "alone", merge: true, expiresAt: h.now + 10_000 })
  assert.equal(h.submitted[0]?.text, "alone")
  h.connector.page({ page: "p1", focused: true, conversation: 61, draft: true })
  const next = h.connector.nextCompose("p1")
  await h.command({ op: "submit", id: "m3", expectedSession: session(61), text: "again", merge: true, expiresAt: h.now + 10_000 })
  await next
  assert.equal(await h.connector.composed("m3", "p1", "   "), false)
  await h.flush()
  assert.equal(h.submitted[1]?.text, "again")
})

test("a page that never picks up the join leaves the dictation to go alone", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 61, draft: true })
  await h.command({ op: "submit", id: "m4", expectedSession: session(61), text: "solo", merge: true, expiresAt: h.now + 10_000 })
  assert.equal(h.submitted.length, 0)
  await h.advance(1500)
  assert.equal(h.submitted[0]?.text, "solo")
})

test("a draft that would run as a command is never joined", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 61, draft: true })
  const next = h.connector.nextCompose("p1")
  await h.command({ op: "submit", id: "m5", expectedSession: session(61), text: "x", merge: true, expiresAt: h.now + 10_000 })
  await next
  assert.equal(await h.connector.composed("m5", "p1", "/skill:release"), false)
  await h.flush()
  assert.equal(h.submitted.length, 0)
  assert.equal(h.events("refused")[0].reason, "draft")
})

test("a question a conversation asks the user is what it waits on, until it is answered", async () => {
  const h = harness()
  await h.connect()
  h.connector.waiting(new Map([[61, waitingFor("Which way?", [{ text: "Ship it now?", options: [{ label: "Yes" }, { label: "Later" }] }])]]))
  await h.flush()
  const [asked] = h.events("waiting")
  assert.equal(asked.session, session(61))
  assert.deepEqual(asked.waiting, { kind: "select", title: "Ship it now?", detail: "Yes, Later" })
  h.connector.waiting(new Map())
  await h.flush()
  assert.equal(h.events("waiting").at(-1).waiting, undefined)
})

test("a user rename reports the new name and a generated title never does", async () => {
  const h = harness()
  await h.connect()
  h.state.conversations[1] = { ...h.state.conversations[1], title: "Login fix", named: true }
  h.connector.changed()
  await h.flush()
  assert.deepEqual(h.events("title").map((t) => [t.session, t.text]), [[session(61), "Login fix"]])
  h.state.conversations[1] = { ...h.state.conversations[1], title: "Summary title", named: false }
  h.connector.changed()
  await h.flush()
  assert.deepEqual(h.events("title").at(-1).text, "")
})

test("a new conversation says hello and a removed one leaves the poll", async () => {
  const h = harness()
  await h.connect()
  h.state.conversations.push({ id: 70, named: false, cwd: "/h/wt/70", busy: false })
  h.connector.changed()
  await h.connect()
  assert.ok(h.events("hello").some((hello) => hello.session === session(70)))
  h.state.conversations = h.state.conversations.filter((c) => c.id !== 61)
  h.connector.changed()
  await h.flush()
  assert.ok(!h.poll()!.body.members.some((m: any) => m.session === session(61)))
})

test("asking to read a reply aloud asks the app for this conversation's turn", async () => {
  const h = harness()
  await h.connect()
  const answer = h.connector.readAloud(61)
  await h.flush()
  const notify = h.requests.find((r) => r.body.op === "notify")!
  assert.equal(notify.body.session, session(61))
  notify.answer(200, JSON.stringify({ spoken: true }))
  assert.equal(await answer, true)
  assert.ok(readAloudReply("KeyScribe", true).includes("report your final reply"))
  assert.equal(readAloudToolName("keyscribe-dev"), "keyscribe_dev_tell_me_when_done")
})

test("each conversation shows the name the app gives it, and a conversation it has not named shows none", async () => {
  const h = harness()
  await h.connect()
  assert.ok(h.events("hello").every((hello) => hello.features.includes("label")))
  assert.equal(h.connector.label(61), null)
  await h.command({ op: "status", id: "s1", expectedSession: session(61), text: "\u201Clogin fix\u201D" })
  assert.equal(h.connector.label(61), "\u201Clogin fix\u201D")
  assert.equal(h.connector.label(53), null)
  await h.command({ op: "status", id: "s2", expectedSession: session(61), text: "x".repeat(500) })
  assert.equal(h.connector.label(61), "x".repeat(200))
  assert.equal(h.connector.label(99), null)
})

test("the page shows no name while the conversation is quiet, after the connection is lost, or once retired", async () => {
  const quiet = harness()
  await quiet.connect()
  await quiet.command({ op: "status", id: "s1", expectedSession: session(61), text: "\u201Clogin fix\u201D" })
  await quiet.command({ op: "quiet", id: "q", expectedSession: session(61) })
  assert.equal(quiet.connector.label(61), null)

  const lost = harness()
  await lost.connect()
  await lost.command({ op: "status", id: "s1", expectedSession: session(61), text: "\u201Clogin fix\u201D" })
  lost.poll()!.answer(500)
  await lost.flush()
  assert.equal(lost.connector.label(61), null)

  const retired = harness()
  await retired.connect()
  await retired.command({ op: "status", id: "s1", expectedSession: session(61), text: "\u201Clogin fix\u201D" })
  await retired.command({ op: "retire", id: "r", expectedSession: session(61) })
  assert.equal(retired.connector.label(61), null)
})

test("only a title the user or the conversation's creator gave names it, never its first message or a summary", () => {
  assert.equal(namedByUser(undefined, undefined), false, "a conversation Ultimate titles from its first message")
  assert.equal(namedByUser(undefined, "One-word kiwi reply"), false, "a summary that has not written a title")
  assert.equal(namedByUser("One-word kiwi reply", "One-word kiwi reply"), false, "a title the summary wrote")
  assert.equal(namedByUser("release notes", undefined), true, "a rename, which clears the generated title, or a title given at creation")
  assert.equal(namedByUser("release notes", "One-word kiwi reply"), true, "a title the user set after a summary")
})

test("the app retiring the extension stops it", async () => {
  const h = harness()
  await h.connect()
  await h.command({ op: "retire", id: "r", expectedSession: session(61) })
  assert.ok(h.logs.some((log) => log.includes("retired")))
  const before = h.requests.length
  h.state.conversations[1].busy = true
  h.connector.changed()
  await h.flush()
  assert.equal(h.requests.length, before)
})

test("a draft is joined with a single space", () => {
  assert.equal(joined("first", "second"), "first second")
  assert.equal(joined("first\n", "second"), "first\nsecond")
})

test("a prompt the user types is reported as typed, and a dictation placed before its submit returns is not", async () => {
  let release: (n: number) => void = () => {}
  const h = harness({ submit: () => new Promise<number>((resolve) => { release = resolve }) })
  await h.connect()
  await h.command({ op: "submit", id: "mine", expectedSession: session(61), text: "dictated", expiresAt: h.now + 10_000 })
  h.connector.placed(300, 9100, "mine")
  h.connector.input(61, 9100, "pi.user", "dictated")
  release(300)
  await h.flush()
  assert.equal(h.events("typed").length, 0)
  assert.equal(h.events("submitted")[0]?.request, "mine")
  h.connector.input(61, 9200, "pi.user", "typed by hand")
  h.connector.input(61, 9300, "board.delivered", "a message from another agent")
  await h.flush()
  assert.deepEqual(h.events("typed").map((t) => [t.session, t.prompts]), [[session(61), 1]])
})

test("a dictation queued before the user typed there is refused rather than sent stale", async () => {
  const h = harness()
  await h.connect()
  h.connector.input(61, 9400, "pi.user", "typed by hand")
  await h.flush()
  await h.command({ op: "submit", id: "stale", expectedSession: session(61), text: "x", expectedPrompts: 0, expiresAt: h.now + 10_000 })
  await h.command({ op: "submit", id: "fresh", expectedSession: session(61), text: "y", expectedPrompts: 1, expiresAt: h.now + 10_000 })
  assert.equal(h.events("refused").find((r) => r.request === "stale")?.reason, "typedSince")
  assert.deepEqual(h.submitted.map((s) => s.requestId), ["fresh"])
})

test("a focused page that keeps reporting the same thing is told once", async () => {
  const h = harness()
  await h.connect()
  const page = { page: "p1", focused: true, conversation: 61, draft: false }
  h.connector.page(page)
  await h.flush()
  const before = h.events("shown").length
  await h.advance(5000)
  h.connector.page(page)
  await h.flush()
  assert.equal(h.events("shown").length, before)
})

test("a new reason the page cannot take a take is told, also while the previous report is in flight", async () => {
  const h = harness({ holdShown: true })
  await h.connect()
  for (const request of h.requests.filter(r => r.body.op === "shown" && !r.settled)) request.answer(200, "{}")
  await h.flush()
  h.connector.page({ page: "p1", focused: true, conversation: null, draft: false, problem: "A dialog covers Ultimate’s composer." })
  const inFlight = h.requests.filter(r => r.body.op === "shown" && !r.settled).at(-1)!
  h.connector.page({ page: "p1", focused: true, conversation: null, draft: false, problem: "Ultimate’s composer is not ready." })
  inFlight.answer(200, "{}")
  await h.flush()
  for (const request of h.requests.filter(r => r.body.op === "shown" && !r.settled)) request.answer(200, "{}")
  await h.flush()
  assert.deepEqual(h.events("shown").slice(-2).map(e => e.problem), ["A dialog covers Ultimate’s composer.", "Ultimate’s composer is not ready."])
})

test("typing follows the visible writable composer, including a side chat over its parent", async () => {
  const { typingConversation } = await import("../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts")
  assert.equal(typeof typingConversation, "function")
  assert.equal(typingConversation([{ id: 53, active: true }], false), 53)
  assert.equal(typingConversation([{ id: 70, active: true }], false), 70)
  assert.equal(typingConversation([{ id: 70, active: false }], false), 70)
  assert.equal(typingConversation([{ id: 53, active: false }, { id: 70, active: true }], false), 70)
  assert.equal(typingConversation([{ id: 53, active: false }, { id: 70, active: false }], false), null)
  assert.equal(typingConversation([{ id: 53, active: true }], true), null)
  assert.equal(typingConversation([], false), null)
})

test("an unlisted page reports what it shows rather than assigning its take to another conversation", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 999, draft: false })
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, false)
  assert.equal(h.events("shown").at(-1).problem, "Ultimate shows conversation 999, but it is not listed.")
  h.connector.page({ page: "p1", focused: true, conversation: null, draft: false, problem: "A dialog covers Ultimate’s composer." })
  await h.flush()
  assert.equal(h.events("shown").at(-1).problem, "A dialog covers Ultimate’s composer.")
  assert.deepEqual(h.submitted, [])
})

test("a listed conversation with an unavailable composer never claims focus", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 53, draft: false, problem: "Ultimate’s composer is not ready." })
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, false)
  assert.equal(h.events("shown").at(-1).problem, "Ultimate’s composer is not ready.")
})

test("a page showing a new conversation greets it before the deferred listing refresh", async () => {
  const h = harness()
  await h.connect()
  h.state.conversations.push({ id: 70, named: false, cwd: "/w", busy: false })
  h.connector.page({ page: "p1", focused: true, conversation: 70, draft: false })
  await h.connect()
  assert.ok(h.events("hello").some(e => e.session === session(70)))
  assert.equal(h.events("shown").at(-1).session, session(70))
  assert.equal(h.events("shown").at(-1).on, true)
})

for (const order of [["page", "listed", "hello"], ["listed", "page", "hello"], ["listed", "hello", "page"]]) {
  test(`a new page becomes reachable as soon as its hello settles: ${order.join(", ")}`, async () => {
    const h = harness()
    await h.connect()
    for (const event of order) {
      if (event === "page") h.connector.page({ page: "new", focused: true, conversation: 71, draft: false })
      else if (event === "listed") {
        h.state.conversations.push({ id: 71, named: false, cwd: "/w/app", busy: false })
        h.connector.changed()
      } else await h.connect()
      await h.flush()
    }
    assert.equal(h.events("shown").at(-1).on, true)
    assert.equal(h.events("shown").at(-1).session, session(71))
  })
}

test("Tab new side-chat mode targets a new side chat and never routes to @ultimate", async () => {
  const { typingTarget } = await import("../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts") as any
  assert.equal(typeof typingTarget, "function")
  assert.deepEqual(typingTarget([{ id: 53, active: true, sideMode: true }], false), { kind: "newSideChat", parent: 53 })
  assert.deepEqual(typingTarget([{ id: 53, active: false, sideMode: true }], false), { kind: "newSideChat", parent: 53 })
  assert.deepEqual(typingTarget([{ id: 53, active: true, sideMode: false }], false), { kind: "conversation", id: 53 })
  assert.deepEqual(typingTarget([{ id: 53, active: true, sideMode: true }], true), { kind: "none" })
})

test("a page in Tab new side-chat mode reports newConversation with its pageConversation and handles start", async () => {
  const h = harness()
  await h.connect()
  assert.ok(h.events("hello")[0].features.includes("start"))
  h.connector.page({ page: "p1", focused: true, conversation: null, newConversation: true, parent: 53, pageConversation: 53, draft: false } as any)
  await h.flush()
  const shown = h.events("shown").at(-1)
  assert.equal(shown.on, false)
  assert.equal(shown.newConversation, true)
  assert.equal(shown.pageConversation, "53")
  const next = h.connector.nextCompose("p1")
  await h.command({ op: "start", id: "s1", expectedSession: session(53), text: "Reply only ready.", expiresAt: h.now + 10_000 })
  const ask = await next
  assert.deepEqual(ask, { id: "s1", kind: "start", conversation: 53, text: "Reply only ready." })
  await (h.connector as any).started("s1", "p1", { sent: true, withDraft: false })
  await h.flush()
  assert.deepEqual(h.submitted, [])
  assert.equal(h.events("submitted").at(-1).request, "s1")
})

test("a start command refuses cleanly when the page leaves side-chat mode or the open action declines", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 53, pageConversation: 53, draft: false } as any)
  await h.flush()
  await h.command({ op: "start", id: "s-gone", expectedSession: session(53), text: "nope", expiresAt: h.now + 10_000 })
  await h.flush()
  assert.equal(h.events("refused").at(-1).request, "s-gone")
  assert.equal(h.events("refused").at(-1).reason, "gone")
  h.connector.page({ page: "p1", focused: true, conversation: null, newConversation: true, parent: 53, pageConversation: 53, draft: false } as any)
  await h.flush()
  const next = h.connector.nextCompose("p1")
  await h.command({ op: "start", id: "s-fail", expectedSession: session(53), text: "hi", expiresAt: h.now + 10_000 })
  await next
  await (h.connector as any).started("s-fail", "p1", { sent: false, reason: "failed", detail: "@ultimate has no finished turn to fork yet" })
  await h.flush()
  assert.equal(h.events("refused").at(-1).request, "s-fail")
  assert.equal(h.events("refused").at(-1).detail, "@ultimate has no finished turn to fork yet")
})

test("a side chat carries its parent pageConversation on shown and a new side chat turn carries its prompt digest on turnStarted", async () => {
  const { promptDigest } = await import("../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts")
  const h = harness()
  h.state.conversations.push({ id: 147, named: false, cwd: "/w/app", busy: false })
  h.connector.changed()
  await h.connect()
  h.connector.page({ page: "p1", focused: true, conversation: 147, pageConversation: 53, draft: false })
  await h.flush()
  const shown = h.events("shown").at(-1)
  assert.equal(shown.session, session(147))
  assert.equal(shown.on, true)
  assert.equal(shown.pageConversation, "53")
  h.connector.input(147, 9001, "pi.user", "Reply only tabside.")
  await h.flush()
  const started = h.events("turnStarted").at(-1)
  assert.equal(started.session, session(147))
  assert.equal(started.prompt, promptDigest("Reply only tabside."))
})

test("a brand-new conversation whose first input arrives before its hello settles still reports turnStarted with its prompt digest", async () => {
  const { promptDigest } = await import("../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts")
  const h = harness()
  await h.connect()
  h.state.conversations.push({ id: 238, named: false, cwd: "/w/app", busy: false })
  h.connector.input(238, 9100, "pi.user", "Reply with only tabside.")
  await h.connect()
  await h.flush()
  const started = h.events("turnStarted").find(e => e.session === session(238))
  assert.ok(started, "turnStarted must be emitted once hello settles")
  assert.equal(started.prompt, promptDigest("Reply with only tabside."))
})

test("an out-of-order page report never overwrites a newer dialog or side-chat state", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "p1", seq: 2, focused: true, conversation: null, pageConversation: 53, draft: false, problem: "A dialog covers Ultimate’s composer." } as any)
  h.connector.page({ page: "p1", seq: 1, focused: true, conversation: 53, pageConversation: 53, draft: false } as any)
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, false)
  assert.equal(h.events("shown").at(-1).problem, "A dialog covers Ultimate’s composer.")
  h.connector.page({ page: "p1", seq: 4, focused: true, conversation: null, newConversation: true, parent: 53, pageConversation: 53, draft: false } as any)
  h.connector.page({ page: "p1", seq: 3, focused: true, conversation: 53, pageConversation: 53, draft: false } as any)
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, false)
  assert.equal(h.events("shown").at(-1).newConversation, true)
  h.connector.page({ page: "p1", seq: 5, focused: true, conversation: 53, pageConversation: 53, draft: false } as any)
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, true)
  assert.equal(h.events("shown").at(-1).session, session(53))
})

test("input, title, and waiting arriving while hello is in flight are reported once hello settles", async () => {
  const h = harness()
  await h.connect()
  h.state.conversations.push({ id: 140, named: false, cwd: "/w/app", busy: false })
  h.connector.changed()
  await h.flush()
  assert.equal(h.events("hello").filter(e => e.session === session(140)).length, 1)
  assert.equal(h.events("hello").find(e => e.session === session(140))?.prompts, 0)
  h.connector.input(140, 1001, "pi.user", "Reply only ready.")
  h.state.conversations.find(c => c.id === 140)!.title = "Side"
  h.state.conversations.find(c => c.id === 140)!.named = true
  h.connector.changed()
  h.connector.waiting(new Map([[140, { kind: "question", title: "Confirm" }]]))
  await h.connect()
  await h.flush()
  const typed = h.events("typed").find(e => e.session === session(140))
  assert.equal(typed?.prompts, 1)
  const title = h.events("title").find(e => e.session === session(140))
  assert.equal(title?.text, "Side")
  const waiting = h.events("waiting").find(e => e.session === session(140))
  assert.equal(waiting?.waiting?.title, "Confirm")
  await h.command({ op: "submit", id: "r-sync", expectedSession: session(140), text: "hello", expectedPrompts: 1, expiresAt: h.now + 10_000 })
  await h.flush()
  assert.equal(h.submitted.at(-1)?.id, 140)
})

test("a live page state change overrides a ghost page from before a reload", async () => {
  const h = harness()
  await h.connect()
  h.connector.page({ page: "new", seq: 1, focused: true, conversation: 53, pageConversation: 53, draft: false })
  h.connector.page({ page: "old", seq: 9, focused: true, conversation: 53, pageConversation: 53, draft: false })
  await h.flush()
  h.connector.page({ page: "new", seq: 2, focused: true, conversation: null, pageConversation: 53, draft: false, problem: "A dialog covers Ultimate’s composer." })
  await h.flush()
  assert.equal(h.events("shown").at(-1).on, false)
  assert.equal(h.events("shown").at(-1).problem, "A dialog covers Ultimate’s composer.")
})

test("a page dialog reported before any member finishes hello is still sent once a member is reachable", async () => {
  const h = harness({ conversations: [] })
  await h.connect()
  h.connector.page({ page: "p1", seq: 1, focused: true, conversation: null, pageConversation: 53, draft: false, problem: "A dialog covers Ultimate’s composer." })
  await h.flush()
  h.state.conversations.push({ id: 53, title: "@ultimate", named: true, cwd: "/w/app", busy: false })
  h.connector.changed()
  await h.connect()
  await h.flush()
  assert.equal(h.events("shown").at(-1)?.on, false)
  assert.equal(h.events("shown").at(-1)?.problem, "A dialog covers Ultimate’s composer.")
})
