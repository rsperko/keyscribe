import assert from "node:assert/strict"
import { test } from "node:test"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { connector, nodeHost, readAloudToolName, type Host, type Response } from "../../Sources/KeyScribe/Resources/PiConnector/index.ts"

type Request = {
  path: string
  body: any
  auth: string
  socketPath: string
  settled: boolean
  cancelled: boolean
  answer: (status: number, text?: string) => void
  refuse: () => void
}

type Options = {
  configPath?: string | null; loadedFrom?: string | null; builtVersion?: string | null; mode?: string; now?: number; api?: Record<string, unknown>
  watches?: boolean
}

function harness(options: Options = {}) {
  const handlers = new Map<string, Array<(event: any, ctx: any) => unknown>>()
  const requests: Request[] = []
  const watching: Array<{ folder: string; fn: () => void; broken: () => void; closed: boolean }> = []
  let onWatch: (() => void) | null = null
  const sends: Array<{ text: string; options: any }> = []
  const statuses: Array<string | undefined> = []
  const execs: string[][] = []
  const env: Record<string, string | undefined> = {}
  const config = {
    protocol: 2, socketPath: "/tmp/ks.sock", tokenPath: "/tmp/ks-token", readyPath: "/tmp/ks-ready.json", installation: "I1",
    plugin: "keyscribe-dev", environmentKeys: ["CMUX_SURFACE_ID", "MUX_PANE", "ZELLIJ_PANE_ID"],
    focusDefinitions: [
      { id: "cmux", requiresEnv: ["CMUX_SURFACE_ID"], argv: ["/usr/bin/env", "cmux", "focus-panel", "--panel", "{CMUX_SURFACE_ID}"] },
      { id: "mux", requiresEnv: ["MUX_PANE"], argv: ["/opt/mux/bin/mux", "focus", "--pane={MUX_PANE}", "{MUX_PANE}"] },
      { id: "stray", requiresEnv: ["MUX_PANE"], argv: ["/opt/mux/bin/mux", "{ZELLIJ_PANE_ID}"] },
      { id: "relative", requiresEnv: ["MUX_PANE"], argv: ["mux", "{MUX_PANE}"] },
    ],
  }
  const files: Record<string, string | undefined> = {
    "/plugin/keyscribe.json": JSON.stringify(config),
    "/tmp/ks-token": "secret\n",
    "/tmp/ks-ready.json": JSON.stringify({ launch: "L1", protocol: 2 }),
  }
  const fileReads: string[] = []
  const images: Record<string, string> = {}
  const timers: Array<{ at: number; fn: () => void; id: number }> = []
  let timerId = 0
  let now = options.now ?? 1_000_000
  const live = { session: "s1", name: undefined as string | undefined, idle: true, editor: "", cwd: "/work", mode: options.mode ?? "tui", model: { id: "m" } as { id: string } | undefined }
  let keyHandler: ((data: string) => unknown) | null = null
  let execCode = 0
  let sendFails = false
  let sendRejects: string | null = null
  let sendDispatchesInput = false
  let autoEvents = false

  const host: Host = {
    pid: 4242,
    now: () => now,
    env: (name) => env[name],
    read: async (path) => {
      fileReads.push(path)
      const text = files[path]
      if (text === undefined) throw new Error("ENOENT")
      return text
    },
    readBase64: async (path) => {
      fileReads.push(path)
      const data = images[path]
      if (data === undefined) throw new Error("ENOENT")
      return data
    },
    after: (ms, fn) => {
      const id = ++timerId
      timers.push({ at: now + ms, fn, id })
      return () => {
        const index = timers.findIndex((t) => t.id === id)
        if (index >= 0) timers.splice(index, 1)
      }
    },
    exec: async (command, args) => {
      execs.push([command, ...args])
      return { code: execCode }
    },
    ...(options.watches ? {
      watch: (folder: string, fn: () => void, broken: () => void) => {
        const watch = { folder, fn, broken, closed: false }
        watching.push(watch)
        onWatch?.()
        return () => { watch.closed = true }
      },
    } : {}),
    post: (socketPath, path, body, token) => {
      let resolve: (r: Response) => void = () => {}
      let reject: (e: Error) => void = () => {}
      const response = new Promise<Response>((res, rej) => { resolve = res; reject = rej })
      const request: Request = {
        path, body: JSON.parse(body), auth: token, socketPath, settled: false, cancelled: false,
        answer: (status, text = "{}") => {
          request.settled = true
          resolve({ status, ok: status >= 200 && status < 300, text })
        },
        refuse: () => {
          request.settled = true
          reject(new Error("connect ECONNREFUSED"))
        },
      }
      requests.push(request)
      if (autoEvents && path === "/event") queueMicrotask(() => { if (!request.settled) request.answer(200) })
      return {
        response,
        cancel: () => {
          if (request.settled) return
          request.settled = true
          request.cancelled = true
          reject(new Error("cancelled"))
        },
      }
    },
  }

  const ctx = {
    get mode() { return live.mode },
    hasUI: true,
    get cwd() { return live.cwd },
    sessionManager: { getSessionId: () => live.session, getCwd: () => live.cwd },
    get model() { return live.model },
    isIdle: () => live.idle,
    ui: {
      setStatus: (_key: string, text: string | undefined) => { statuses.push(text) },
      getEditorText: () => live.editor,
      setEditorText: (text: string) => { live.editor = text },
      onTerminalInput: (handler: (data: string) => unknown) => {
        keyHandler = handler
        return () => { if (keyHandler === handler) keyHandler = null }
      },
    },
  }

  const tools: any[] = []
  const commands = new Map<string, any>()
  const notes: string[] = []
  const commandCtx = { ...ctx, ui: { ...ctx.ui, notify: (text: string) => { notes.push(text) } } }
  const pi = {
    registerTool: (tool: any) => { tools.push(tool) },
    registerCommand: (name: string, options: any) => { commands.set(name, options) },
    on: (event: string, handler: (event: any, ctx: any) => unknown) => {
      handlers.set(event, [...(handlers.get(event) ?? []), handler])
      return () => {}
    },
    sendUserMessage: (content: any, sendOptions: any) => {
      if (sendFails) throw new Error("agent is busy")
      const text = typeof content === "string" ? content : content.filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n")
      sends.push({ text, content, options: sendOptions })
      if (sendDispatchesInput) emit("input", { text, source: "extension" })
      if (sendRejects !== null) return Promise.reject(new Error(sendRejects))
      return Promise.resolve()
    },
    getSessionName: () => live.name,
    exec: async () => ({ code: 0 }),
    ...options.api,
  }

  connector(pi as any, host, { configPath: options.configPath === undefined ? "/plugin/keyscribe.json" : options.configPath, loadedFrom: options.loadedFrom ?? null, builtVersion: options.builtVersion ?? null })

  const emit = (event: string, payload: any = {}) => {
    for (const handler of handlers.get(event) ?? []) handler({ type: event, ...payload }, ctx)
  }
  const settle = async () => {
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve))
  }
  const advance = async (ms: number) => {
    const end = now + ms
    for (;;) {
      await settle()
      const due = timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at || a.id - b.id)[0]
      if (!due) break
      timers.splice(timers.indexOf(due), 1)
      now = Math.max(now, due.at)
      due.fn()
    }
    now = end
    await settle()
  }
  const open = (path?: string) => requests.filter((r) => !r.settled && (!path || r.path === path))
  const events = () => requests.filter((r) => r.path === "/event").map((r) => r.body)
  const ops = () => events().map((b) => b.op)
  const replies = () => events().filter((b) => ["ack", "submitted", "refused", "focused"].includes(b.op))

  async function start(reason = "startup") {
    emit("session_start", { reason })
    await settle()
  }

  async function connect(reason = "startup") {
    await start(reason)
    const hello = open("/event")[0]
    assert.ok(hello, "no hello was sent")
    assert.equal(hello.body.op, "hello")
    hello.answer(200)
    autoEvents = true
    await settle()
    assert.equal(open("/poll").length, 1)
    return hello.body
  }

  async function deliver(commands: any[]) {
    open("/poll")[0].answer(200, JSON.stringify(commands))
    await settle()
  }

  async function answerEvents() {
    for (let i = 0; i < 100 && open("/event").length; i++) {
      open("/event")[0].answer(200)
      await settle()
    }
  }

  const typed = async (text = "typed by me") => {
    emit("input", { text, source: "interactive" })
    await settle()
  }
  const accepted = async () => {
    const last = sends[sends.length - 1]
    emit("input", { text: last.text, source: "extension" })
    live.idle = false
    emit("agent_start")
    emit("message_start", { message: { role: "user", content: [{ type: "text", text: last.text }] } })
    await settle()
  }
  const finished = async (aborted = false) => {
    live.idle = true
    emit("agent_settled", { aborted })
    await settle()
  }
  const key = async () => {
    assert.ok(keyHandler, "no terminal input handler")
    keyHandler("x")
    await settle()
  }
  const ready = (launch?: string, protocol = 2) => {
    files["/tmp/ks-ready.json"] = launch === undefined ? undefined : JSON.stringify({ launch, protocol })
  }
  const readyChecks = () => fileReads.filter((p) => p === "/tmp/ks-ready.json").length
  const submit = (id = "r1", text = "run the tests", extra: Record<string, unknown> = {}) => ({ op: "submit", id, expectedSession: live.session, text, expiresAt: now + 8_000, ...extra })

  const runCommand = (name: string, args: string) => commands.get(name).handler(args, commandCtx)
  const turn = (n: number) => `${events().find((b) => b.op === "hello").instance}.${n}`

  return {
    requests, sends, statuses, execs, env, files, images, live, timers, config, tools, commands, notes, runCommand, watching,
    set onWatch(fn: (() => void) | null) { onWatch = fn },
    set autoEvents(value: boolean) { autoEvents = value },
    get now() { return now },
    set now(value: number) { now = value },
    get keyHandler() { return keyHandler },
    set execCode(code: number) { execCode = code },
    set sendFails(value: boolean) { sendFails = value },
    set sendRejects(value: string | null) { sendRejects = value },
    set sendDispatchesInput(value: boolean) { sendDispatchesInput = value },
    turn, emit, settle, advance, open, events, ops, replies, start, connect, deliver, answerEvents, typed, accepted, finished, key, ready, readyChecks, submit,
  }
}

test("outside the terminal UI the connector does nothing", async () => {
  const h = harness({ mode: "rpc" })
  await h.start()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
  assert.equal(h.readyChecks(), 0)
})

test("a session start says hello with the process, its directory, its name and what it offers", async () => {
  const h = harness()
  h.live.name = "frontend"
  h.env.ZELLIJ_PANE_ID = "7"
  const hello = await h.connect()
  assert.equal(hello.agent, "pi")
  assert.equal(hello.protocol, 2)
  assert.equal(hello.installation, "I1")
  assert.equal(hello.pid, 4242)
  assert.equal(hello.cwd, "/work")
  assert.equal(hello.session, "s1")
  assert.equal(hello.title, "frontend")
  assert.deepEqual(hello.features, ["focus", "focusDefinitions", "label", "readiness", "notify", "images", "check", "steer", "merge"])
  assert.equal(hello.prompts, 0)
  assert.equal(hello.idle, true)
  assert.equal(hello.gap, false)
  assert.deepEqual(hello.environment, { ZELLIJ_PANE_ID: "7" })
  assert.equal(h.requests[0].auth, "secret")
  assert.equal(h.requests[0].socketPath, "/tmp/ks.sock")
})

test("hello reports the version of the code that is running, never the one its settings file names after an update", async () => {
  const built = harness({ builtVersion: "v-loaded" })
  built.files["/plugin/keyscribe.json"] = JSON.stringify({ ...built.config, version: "v-updated" })
  const hello = await built.connect()
  assert.equal(hello.codeVersion, "v-loaded")
  assert.equal("version" in hello, false)
  const unbuilt = harness()
  assert.equal("codeVersion" in (await unbuilt.connect()), false)
})

test("a Pi that exposes its own package to extensions still connects as Pi", async () => {
  const h = harness({ api: { pi: { VERSION: "1.5.0", getAgentDir: () => "/Users/a/.pi/agent" } } })
  const hello = await h.connect()
  assert.equal(hello.agent, "pi")
})

test("hello without a name or terminal facts omits them", async () => {
  const h = harness()
  const hello = await h.connect()
  assert.equal("title" in hello, false)
  assert.equal("environment" in hello, false)
})

test("a resumed or reloaded session says hello as resuming after a gap", async () => {
  for (const reason of ["resume", "reload"]) {
    const h = harness()
    const hello = await h.connect(reason)
    assert.equal(hello.gap, true, reason)
  }
  for (const reason of ["startup", "new", "fork"]) {
    const h = harness()
    const hello = await h.connect(reason)
    assert.equal(hello.gap, false, reason)
  }
})

test("a session that starts busy says so", async () => {
  const h = harness()
  h.live.idle = false
  const hello = await h.connect()
  assert.equal(hello.idle, false)
})

test("what happens before hello is dropped, never replayed, and hello reports the prompt count", async () => {
  const h = harness()
  h.ready(undefined)
  await h.start()
  await h.typed()
  h.live.idle = false
  h.emit("agent_start")
  await h.settle()
  assert.equal(h.requests.length, 0)
  h.ready("L1")
  await h.advance(10_000)
  const hello = h.open("/event")[0]
  assert.equal(hello.body.op, "hello")
  assert.equal(hello.body.prompts, 1)
  assert.equal(hello.body.idle, false)
  hello.answer(200)
  await h.settle()
  assert.deepEqual(h.ops(), ["hello"])
})

const invisible = /^[\u200b\u200c\u200d\u2060]+$/
const started = (h: ReturnType<typeof harness>, text: string) => {
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_start", { message: { role: "user", content: [{ type: "text", text }] } })
}
const arrives = async (h: ReturnType<typeof harness>, text: string) => {
  h.emit("input", { text, source: "extension" })
  started(h, text)
  await h.settle()
}

test("dictation is handed to the agent as a follow-up carrying an invisible mark of its own, and confirmed by its own user message", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests", { expectedPrompts: 0 })])
  assert.equal(h.sends.length, 1)
  assert.ok(h.sends[0].text.startsWith("run the tests"))
  assert.match(h.sends[0].text.slice("run the tests".length), invisible)
  assert.deepEqual(h.sends[0].options, { deliverAs: "followUp" })
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  await h.accepted()
  const sent = h.replies()
  assert.deepEqual(sent.map((b) => b.op), ["ack", "submitted"])
  assert.equal(sent[1].request, "r1")
  assert.equal(sent[1].turn, h.turn(1))
  assert.ok(h.ops().includes("turnStarted"))
})

test("a clipboard image goes to Pi with the words that name its file, and is confirmed like any dictation", async () => {
  const h = harness()
  await h.connect()
  h.images["/clip/shot.png"] = "UE5H"
  h.images["/clip/other.PNG"] = "SlBH"
  await h.deliver([h.submit("r1", "look at /clip/shot.png and /clip/other.PNG", { images: ["/clip/shot.png", "/clip/other.PNG"] })])
  assert.equal(h.sends.length, 1)
  const [words, ...attached] = h.sends[0].content
  assert.equal(words.type, "text")
  assert.ok(words.text.startsWith("look at /clip/shot.png and /clip/other.PNG"))
  assert.deepEqual(attached, [
    { type: "image", data: "UE5H", mimeType: "image/png" },
    { type: "image", data: "SlBH", mimeType: "image/png" },
  ])
  await h.accepted()
  assert.deepEqual(h.replies().map((b) => b.op), ["ack", "submitted"])
})

test("an image that cannot be read, or is not an image Pi takes, leaves only the words naming its file", async () => {
  const h = harness()
  await h.connect()
  h.images["/clip/notes.pdf"] = "JVBE"
  h.images["/clip/photo.jpg"] = "SlBH"
  await h.deliver([h.submit("r1", "read /clip/gone.png and /clip/notes.pdf", { images: ["/clip/gone.png", "/clip/notes.pdf", "/clip/photo.jpg"] })])
  assert.equal(h.sends.length, 1)
  assert.equal(typeof h.sends[0].content, "string")
  assert.ok(h.sends[0].text.startsWith("read /clip/gone.png and /clip/notes.pdf"))
  await h.accepted()
  assert.deepEqual(h.replies().map((b) => b.op), ["ack", "submitted"])
})

test("a send Pi rejects later is refused with its reason, and the next send still goes through", async () => {
  const h = harness()
  await h.connect()
  h.sendRejects = "image could not be processed"
  await h.deliver([h.submit("r1", "look at this")])
  const refused = h.replies().find((b) => b.op === "refused")
  assert.ok(refused, "no refusal")
  assert.equal(refused.request, "r1")
  assert.match(refused.reason, /image could not be processed/)
  h.sendRejects = null
  await h.deliver([h.submit("r2", "and this")])
  await h.accepted()
  assert.deepEqual(h.replies().filter((b) => b.request === "r2").map((b) => b.op), ["ack", "submitted"])
})

test("every submission carries a different mark, and another instance on the same clock never repeats one, even when the clock runs backwards", async () => {
  const h = harness({ now: 1_800_000_000_000 })
  await h.connect()
  await h.deliver([h.submit("r1", "continue")])
  await h.advance(3_000)
  h.now = 1_700_000_000_000
  await h.deliver([h.submit("r2", "continue")])
  const twin = harness({ now: 1_800_000_000_000 })
  await twin.connect()
  await twin.deliver([twin.submit("r3", "continue")])
  const marks = [h.sends[0], h.sends[1], twin.sends[0]].map((send) => send.text.slice("continue".length))
  assert.equal(new Set(marks).size, 3)
  for (const mark of marks) assert.match(mark, invisible)
})

test("a leading slash or bang is sent as plain text", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "/resume"), h.submit("r2", "!ls")])
  await h.accepted()
  assert.ok(h.sends[0].text.startsWith("/resume"))
})

test("a user message the agent received from someone else is no receipt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1")])
  h.emit("input", { text: "other", source: "interactive" })
  h.emit("message_start", { message: { role: "user", content: "other" } })
  await h.settle()
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  assert.equal(h.ops().filter((op) => op === "submitted").length, 0)
})

test("a run that settles before the receipt leaves the outcome open until Pi's own message for it arrives", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1")])
  h.emit("input", { text: h.sends[0].text, source: "extension" })
  await h.finished()
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  started(h, h.sends[0].text)
  await h.settle()
  assert.deepEqual(h.replies().map((b) => b.op), ["ack", "submitted"])
})

test("an input hook slower than three seconds stops the dictation blocking but still gets its receipt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await h.advance(3_000)
  assert.deepEqual(h.replies().map((b) => [b.op, b.reason]), [["ack", undefined]])
  await h.deliver([h.submit("r2", "then lint")])
  assert.equal(h.sends.length, 2)
  assert.deepEqual(h.replies().map((b) => b.op), ["ack", "ack"])
  await arrives(h, h.sends[0].text)
  const sent = h.replies().filter((b) => b.op === "submitted")
  assert.deepEqual(sent.map((b) => [b.request, b.turn]), [["r1", h.turn(1)]])
})

test("when Pi runs the connector's input hook inside the send itself, the message is still confirmed", async () => {
  const h = harness()
  h.sendDispatchesInput = true
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  started(h, h.sends[0].text)
  await h.settle()
  assert.deepEqual(h.replies().map((b) => [b.op, b.request]), [["ack", "r1"], ["submitted", "r1"]])
})

test("another extension's user message is no receipt, even while dictation is awaiting one", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await arrives(h, "from another extension")
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  await h.accepted()
  assert.deepEqual(h.replies().map((b) => [b.op, b.request]), [["ack", "r1"], ["submitted", "r1"]])
})

test("the same words from another extension are not the dictation: unmarked, they confirm nothing, and the marked message still does", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await arrives(h, "run the tests")
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  await h.finished()
  await arrives(h, h.sends[0].text)
  assert.deepEqual(h.replies().map((b) => [b.op, b.request]), [["ack", "r1"], ["submitted", "r1"]])
})

test("dictation changed on its way in still carries its mark, so it is confirmed and reported as changed", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await arrives(h, h.sends[0].text.replace("run the tests", "run the tests, please") + "\n\n[Image resized]")
  const sent = h.replies().filter((b) => b.op === "submitted")
  assert.deepEqual(sent.map((b) => [b.request, b.altered]), [["r1", true]])
})

test("a marked message is confirmed whatever input came last, and carries when Pi had it and when it entered", async () => {
  const h = harness()
  await h.connect()
  const handed = h.now
  await h.deliver([h.submit("r1", "run the tests")])
  await h.typed("typed while it was starting")
  await h.advance(400)
  h.emit("message_start", { message: { role: "user", content: h.sends[0].text } })
  await h.settle()
  const sent = h.replies().filter((b) => b.op === "submitted")
  assert.deepEqual(sent.map((b) => [b.request, b.handedAt, b.seenAt, b.altered]), [["r1", handed, handed + 400, false]])
})

test("identical words submitted twice are each confirmed by their own message, in whichever order they arrive", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "continue")])
  await h.advance(3_000)
  await h.deliver([h.submit("r2", "continue")])
  await arrives(h, h.sends[1].text)
  await h.finished()
  await arrives(h, h.sends[0].text)
  assert.deepEqual(h.replies().filter((b) => b.op === "submitted").map((b) => b.request), ["r2", "r1"])
})

test("a message delayed across a reload within the same second confirms nothing in the new instance, whose own submission is still confirmed", async () => {
  const old = harness({ now: 1_800_000_000_000 })
  await old.connect()
  await old.deliver([old.submit("r1", "continue")])
  const h = harness({ now: 1_800_000_000_000 })
  await h.connect()
  await h.deliver([h.submit("r2", "continue")])
  await arrives(h, old.sends[0].text)
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  await h.finished()
  await arrives(h, h.sends[0].text)
  assert.deepEqual(h.replies().map((b) => [b.op, b.request]), [["ack", "r2"], ["submitted", "r2"]])
})

test("a submission dropped unanswered when the list is full stays uncertain, and its late message confirms nothing else", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r0", "continue")])
  await h.advance(3_000)
  for (let i = 1; i <= 8; i++) {
    await h.deliver([h.submit(`r${i}`, `message ${i}`)])
    await h.advance(3_000)
  }
  await h.deliver([h.submit("r9", "continue")])
  await arrives(h, h.sends[0].text)
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 0)
  await h.finished()
  await arrives(h, h.sends[9].text)
  assert.deepEqual(h.replies().filter((b) => b.op === "submitted").map((b) => b.request), ["r9"])
})

test("a submission whose connection was lost is confirmed on the next connection, and the next submission by its own message", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "continue")])
  await h.advance(310_000)
  const hellos = h.events().filter((b) => b.op === "hello")
  assert.equal(hellos.length, 2)
  await h.deliver([h.submit("r2", "continue")])
  await arrives(h, h.sends[0].text)
  await h.finished()
  await arrives(h, h.sends[1].text)
  const sent = h.replies().filter((b) => b.op === "submitted")
  assert.deepEqual(sent.map((b) => [b.request, b.connection]), [["r1", hellos[1].connection], ["r2", hellos[1].connection]])
})

test("a confirmation lost with its connection is sent again once the connector says hello again", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  h.autoEvents = false
  await h.accepted()
  assert.ok(h.open("/event").length > 0)
  await h.advance(2_000)
  const hello = h.open("/event").find((r) => r.body.op === "hello")
  assert.ok(hello, "no second hello")
  hello.answer(200)
  h.autoEvents = true
  await h.settle()
  await h.answerEvents()
  const sent = h.replies().filter((b) => b.op === "submitted")
  assert.equal(sent.at(-1).request, "r1")
  assert.equal(sent.at(-1).connection, hello.body.connection)
})

test("a confirmation the app already took is not sent again", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await h.accepted()
  await h.advance(310_000)
  await h.answerEvents()
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 1)
})

test("Pi stalling past an event's deadline does not count as a lost connection", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  await h.typed()
  assert.equal(h.open("/event").length, 1)
  h.now += 5_000
  await h.advance(0)
  assert.equal(h.open("/event").length, 1)
  h.open("/event")[0].answer(200)
  await h.advance(1_000)
  assert.equal(h.events().filter((b) => b.op === "hello").length, 1)
})

test("an event the app never answers still loses the connection when Pi is not stalled", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  await h.typed()
  await h.advance(2_000)
  assert.equal(h.events().filter((b) => b.op === "hello").length, 2)
})

let checks = 0
const check = (h: ReturnType<typeof harness>, request: string) =>
  ({ op: "check", id: `check-${request}-${++checks}`, expectedSession: h.live.session, request, expiresAt: h.now + 2_000 })
const checked = (h: ReturnType<typeof harness>) => h.events().filter((b) => b.op === "checked")

test("a check says whether a dictation is still held, handed to Pi, in the conversation, refused or unknown", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1", "run the tests")])
  await h.deliver([check(h, "r1")])
  await h.advance(3_000)
  const handed = h.now
  await h.deliver([check(h, "r1")])
  await h.advance(500)
  await h.accepted()
  await h.deliver([check(h, "r1"), check(h, "r9")])
  h.sendFails = true
  await h.finished()
  await h.deliver([h.submit("r2", "lint")])
  const last = check(h, "r2")
  await h.deliver([last])
  assert.equal(checked(h).at(-1).check, last.id)
  assert.deepEqual(checked(h).map((b) => [b.request, b.state]), [
    ["r1", "holding"], ["r1", "handed"], ["r1", "seen"], ["r9", "unknown"], ["r2", "refused"],
  ])
  const seen = checked(h)[2]
  assert.equal(seen.turn, h.turn(1))
  assert.equal(seen.handedAt, handed)
  assert.equal(seen.seenAt, handed + 500)
  assert.match(checked(h)[4].reason, /agent is busy/)
})

test("a check says another message entered while a dictation waited for its own", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await arrives(h, "from another extension")
  await h.deliver([check(h, "r1")])
  assert.deepEqual(checked(h).map((b) => [b.state, b.miss]), [["handed", "other"]])
})

test("only a bounded number of late submissions wait for a receipt, oldest forgotten first", async () => {
  const h = harness()
  await h.connect()
  for (let i = 1; i <= 9; i++) {
    await h.deliver([h.submit(`r${i}`, `message ${i}`)])
    await h.advance(3_000)
  }
  assert.equal(h.sends.length, 9)
  h.emit("input", { text: h.sends[1].text, source: "extension" })
  for (const send of [h.sends[0], h.sends[1]]) {
    h.emit("message_start", { message: { role: "user", content: send.text } })
  }
  await h.settle()
  assert.deepEqual(h.replies().filter((b) => b.op === "submitted").map((b) => b.request), ["r2"])
})

test("a turn's final assistant text is reported when it completes, without thinking or tool calls", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "thinking", thinking: "plan" }, { type: "text", text: "Looking." }, { type: "toolCall", id: "t1", name: "bash", arguments: {} }] } })
  h.emit("message_end", { message: { role: "toolResult", content: [{ type: "text", text: "tool output" }] } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "thinking", thinking: "done" }, { type: "text", text: "All green." }] } })
  await h.finished()
  const done = h.events().filter((b) => b.op === "turnComplete")
  assert.deepEqual(done.map((b) => [b.reason, b.answer]), [["complete", "All green."]])
})

test("a turn without assistant text reports an empty answer, and the next turn starts fresh", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "text", text: "first" }] } })
  await h.finished()
  h.live.idle = false
  h.emit("agent_start")
  await h.finished()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => b.answer), ["first", ""])
})

test("a turn whose final response failed reports an error, never the progress text before it", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "Looking into it." }, { type: "toolCall", id: "t1", name: "bash", arguments: {} }] } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "error", content: [] } })
  await h.finished()
  const done = h.events().filter((b) => b.op === "turnComplete")
  assert.deepEqual(done.map((b) => [b.reason, "answer" in b]), [["error", false]])
})

test("an empty final response leaves no earlier text as the answer", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "Looking into it." }] } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [] } })
  await h.finished()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => [b.reason, b.answer]), [["complete", ""]])
})

test("an answer full of characters JSON must escape still fits the event queue and arrives", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: '"'.repeat(20000) } })
  await h.finished()
  const done = h.events().filter((b) => b.op === "turnComplete")
  assert.equal(done.length, 1)
  assert.ok(JSON.stringify(done[0].answer).length <= 8 * 1024)
  assert.equal(h.events().filter((b) => b.op === "hello").length, 1)
})

test("a run Pi retries before it settles stays one turn, and its recovered answer is reported once", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  await h.accepted()
  h.emit("message_end", { message: { role: "assistant", stopReason: "error", content: [] } })
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "All green." }] } })
  await h.finished()
  assert.deepEqual(h.ops().filter((op) => op === "turnStarted").length, 1)
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => [b.reason, b.answer]), [["complete", "All green."]])
  assert.deepEqual(h.replies().filter((b) => b.op === "submitted").map((b) => b.turn), [h.turn(1)])
})

test("a run whose settlement was missed is closed when the user types into an idle Pi, so the session is never stuck busy", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.live.idle = true
  await h.typed()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "Hi." }] } })
  await h.finished()
  assert.deepEqual(h.events().filter((b) => ["turnStarted", "turnComplete"].includes(b.op)).map((b) => [b.op, b.turn ?? b.reason, b.answer]), [
    ["turnStarted", h.turn(1), undefined], ["turnComplete", "unknown", undefined], ["turnStarted", h.turn(2), undefined], ["turnComplete", "complete", "Hi."],
  ])
})

test("a run whose settlement never came is closed once Pi has been idle across two checks, so dictation is not held forever", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.live.idle = true
  await h.advance(4_000)
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => b.reason), ["unknown"])
  await h.answerEvents()
  await h.deliver([h.submit("r1", "run the tests")])
  assert.equal(h.sends.length, 1)
})

test("a long run that is still busy is never closed by the idle check", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  await h.advance(20_000)
  assert.equal(h.events().filter((b) => b.op === "turnComplete").length, 0)
  await h.finished()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => b.reason), ["complete"])
})

test("a single idle moment during settlement does not close the run early", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  await h.advance(1_000)
  h.live.idle = true
  await h.advance(2_000)
  await h.finished()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => b.reason), ["complete"])
})

test("a very long answer crosses the bridge bounded to its opening and its ending", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("message_end", { message: { role: "assistant", content: "a".repeat(5000) + "b".repeat(5000) + "c".repeat(5000) } })
  await h.finished()
  const answer = h.events().find((b) => b.op === "turnComplete").answer
  assert.ok(answer.length <= 8 * 1024)
  assert.ok(answer.startsWith("a".repeat(100)))
  assert.ok(answer.endsWith("c".repeat(100)))
  assert.ok(answer.includes("[…]"))
})

test("a message the agent rejects outright is refused with its words", async () => {
  const h = harness()
  await h.connect()
  h.sendFails = true
  await h.deliver([h.submit("r1")])
  assert.deepEqual(h.replies().map((b) => [b.op, b.reason]), [["ack", undefined], ["refused", "agent is busy"]])
})

const digest = (text: string) => {
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(text.trim())) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, "0")
}

const steering = async (h: any) => {
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  await h.settle()
  await h.deliver([h.submit("r1", "use the other file")])
  assert.deepEqual(h.sends[0].options, { deliverAs: "steer" })
}

const accepted = (h: any) => h.emit("input", { text: h.sends[0].text, source: "extension", streamingBehavior: "steer" })
const takenIn = (h: any) => h.emit("message_start", { message: { role: "user", content: [{ type: "text", text: h.sends[0].text }] } })

test("a steer is confirmed as soon as Pi accepts it, without a turn, however long the running tool takes", async () => {
  const h = harness()
  await steering(h)
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
  accepted(h)
  await h.settle()
  await h.answerEvents()
  const submitted = h.replies().find((b) => b.op === "submitted")
  assert.equal(submitted?.request, "r1")
  assert.equal(submitted?.turn, "")
})

test("a steer is reported taken into the turn running when it enters the conversation", async () => {
  const h = harness()
  await steering(h)
  accepted(h)
  await h.settle()
  takenIn(h)
  await h.settle()
  await h.answerEvents()
  assert.deepEqual(h.events().filter((b) => b.op === "absorbed").map((b) => [b.turn, b.prompt, b.request]), [[h.turn(1), digest("use the other file"), "r1"]])
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 1)
})

test("a steer Pi carries into a new run is reported taken into that run", async () => {
  const h = harness()
  await steering(h)
  accepted(h)
  h.emit("agent_settled", { aborted: false })
  h.emit("agent_start")
  await h.settle()
  takenIn(h)
  await h.settle()
  await h.answerEvents()
  assert.deepEqual(h.events().filter((b) => b.op === "absorbed").map((b) => b.turn), [h.turn(2)])
})

test("a steer another extension consumed after Pi accepted it is never reported taken in", async () => {
  const h = harness()
  await steering(h)
  accepted(h)
  await h.settle()
  await h.answerEvents()
  assert.deepEqual(h.events().filter((b) => b.op === "absorbed"), [])
})

test("a steer that enters the conversation without an input event is still confirmed with its turn", async () => {
  const h = harness()
  await steering(h)
  takenIn(h)
  await h.settle()
  await h.answerEvents()
  assert.equal(h.replies().find((b) => b.op === "submitted")?.turn, h.turn(1))
})

test("a steer is confirmed only by its own mark, never by another message Pi takes in", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  await h.settle()
  await h.deliver([h.submit("r1", "use the other file")])
  h.emit("input", { text: "use the other file", source: "extension", streamingBehavior: "steer" })
  await h.settle()
  await h.answerEvents()
  assert.deepEqual(h.replies().map((b) => b.op), ["ack"])
})

test("an agent that is busy without a known turn is steered", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  await h.deliver([h.submit("r1")])
  assert.equal(h.sends.length, 1)
  assert.deepEqual(h.sends[0].options, { deliverAs: "steer" })
})

test("dictation while a turn waits on a prompt of its own is refused as a dialog, never steered into it", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  h.emit("ui_prompt_start", { kind: "confirm", title: "Allow?" })
  await h.settle()
  await h.deliver([h.submit("r1")])
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["dialog"])
})

test("a second message is refused as working while the first awaits its receipt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1"), h.submit("r2")])
  assert.equal(h.sends.length, 1)
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["working"])
})

test("dictation decided on an older prompt count is refused as typed since", async () => {
  const h = harness()
  await h.connect()
  await h.typed()
  await h.deliver([h.submit("r1", "x", { expectedPrompts: 0 })])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["typedSince"])
  assert.equal(h.sends.length, 0)
})

test("the connector's own submission never counts as the user typing", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "x", { expectedPrompts: 0 })])
  await h.accepted()
  await h.finished()
  assert.equal(h.ops().filter((op) => op === "typed").length, 0)
  await h.answerEvents()
  await h.deliver([h.submit("r2", "y", { expectedPrompts: 0 })])
  assert.equal(h.sends.length, 2)
})

test("a typed prompt is reported with the new count", async () => {
  const h = harness()
  await h.connect()
  await h.typed()
  await h.typed()
  const typed = h.events().filter((b) => b.op === "typed")
  assert.deepEqual(typed.map((b) => b.prompts), [1, 2])
  assert.equal(typed[0].session, "s1")
})

test("dictation never submits over a message the user is still writing, and leaves it in place", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1")])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["draft"])
  assert.equal(h.live.editor, "half a thought")
  assert.equal(h.sends.length, 0)
})

test("dictation for the conversation in front joins what the user started typing and sends it as one message", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), [])
  assert.equal(h.sends.length, 1)
  assert.ok(h.sends[0].text.startsWith("half a thought run the tests"))
  assert.match(h.sends[0].text.slice("half a thought run the tests".length), invisible)
  assert.equal(h.live.editor, "")
})

test("a draft that already ends in a new line takes the dictation with no extra space", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "first line\n"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.ok(h.sends[0].text.startsWith("first line\nrun the tests"))
})

for (const [why, setUp] of [
  ["Pi runs without its own terminal", (h: any) => { h.live.mode = "rpc" }],
  ["no model is chosen", (h: any) => { h.live.model = undefined }],
  ["the draft would run as a command", (h: any) => { h.live.editor = "  /compact" }],
  ["the draft would run in the shell", (h: any) => { h.live.editor = "!ls" }],
  ["the conversation is being compacted", (h: any) => { h.emit("session_before_compact", {}) }],
] as const) {
  test(`dictation never clears a draft when ${why}`, async () => {
    const h = harness()
    await h.connect()
    h.live.editor = "half a thought"
    setUp(h)
    const typed = h.live.editor
    await h.deliver([h.submit("r1", "run the tests", { merge: true })])
    assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["draft"])
    assert.equal(h.live.editor, typed)
    assert.equal(h.sends.length, 0)
  })
}

test("a joined message Pi refuses to send puts the user's draft back", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  h.sendFails = true
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.equal(h.live.editor, "half a thought")
})

test("a joined message Pi turns away after it was sent puts the user's draft back", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  h.sendRejects = "no API key"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  await h.settle()
  assert.equal(h.live.editor, "half a thought")
})

test("a draft put back never overwrites what the user typed after it was cleared", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  h.sendRejects = "no API key"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  h.live.editor = "something new"
  await h.settle()
  assert.equal(h.live.editor, "something new")
})

test("a draft that ends in a tab takes the dictation with no extra space", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "first\t"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.ok(h.sends[0].text.startsWith("first\trun the tests"))
})

test("a dictation that would run as a command after leading spaces is never joined either", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "  /compact", { merge: true })])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["draft"])
})

test("the receipt of a joined message says it carried the user's draft", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  h.emit("message_start", { message: { role: "user", content: h.sends[0].text } })
  await h.settle()
  assert.deepEqual(h.replies().filter((b) => b.op === "submitted").map((b) => b.withDraft), [true])
})

test("a joined message Pi never takes puts the user's draft back once its receipt is overdue", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.equal(h.live.editor, "")
  await h.advance(3000)
  assert.equal(h.live.editor, "half a thought")
})

test("a joined message that arrives after its draft was put back clears that draft again, so it is never sent twice", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  await h.advance(3000)
  assert.equal(h.live.editor, "half a thought")
  h.emit("message_start", { message: { role: "user", content: h.sends[0].text } })
  await h.settle()
  assert.equal(h.live.editor, "")
})

test("a late joined message never clears what the user changed in the draft put back", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  await h.advance(3000)
  h.live.editor = "half a thought, edited"
  h.emit("message_start", { message: { role: "user", content: h.sends[0].text } })
  await h.settle()
  assert.equal(h.live.editor, "half a thought, edited")
})

test("a joined message Pi took leaves the editor empty after its receipt deadline", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  h.emit("message_start", { message: { role: "user", content: h.sends[0].text } })
  await h.advance(3000)
  assert.equal(h.live.editor, "")
})

test("dictation joins a draft again once compaction ends", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  h.emit("session_before_compact", {})
  h.emit("session_compact_failed", {})
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.equal(h.sends.length, 1)
})

test("a dictation that would run as a command is never joined to a draft", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half a thought"
  await h.deliver([h.submit("r1", "/compact", { merge: true })])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["draft"])
  assert.equal(h.live.editor, "half a thought")
})

test("dictation is refused while the agent shows a dialog and accepted once it closes", async () => {
  const h = harness()
  await h.connect()
  h.emit("ui_prompt_start", { kind: "confirm" })
  await h.deliver([h.submit("r1")])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["dialog"])
  h.emit("ui_prompt_end", { kind: "confirm" })
  await h.answerEvents()
  await h.deliver([h.submit("r2")])
  assert.equal(h.sends.length, 1)
})

test("a dialog is reported with its kind, title, the tool it interrupts and what the agent said, once per span, and its close clears it", async () => {
  const h = harness()
  await h.connect()
  h.emit("message_end", { message: { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "Cleaning up first." }, { type: "toolCall", id: "t1", name: "bash", arguments: {} }] } })
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "bash", args: { command: "rm -rf build" } })
  h.emit("ui_prompt_start", { kind: "select", title: "Allow?" })
  h.emit("ui_prompt_start", { kind: "confirm", title: "Really?" })
  h.emit("ui_prompt_end", { kind: "confirm" })
  h.emit("ui_prompt_end", { kind: "select" })
  await h.advance(0)
  const waiting = h.events().filter((b) => b.op === "waiting")
  assert.deepEqual(waiting.map((b) => b.waiting), [
    { kind: "select", title: "Allow?", tool: "bash", detail: '{"command":"rm -rf build"}', said: "Cleaning up first." }, undefined,
  ])
  assert.equal(waiting[0].session, "s1")
})

test("a dialog with no title outside any tool still reports that it waits", async () => {
  const h = harness()
  await h.connect()
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "read", args: {} })
  h.emit("tool_execution_end", { toolCallId: "t1", toolName: "read" })
  h.emit("ui_prompt_start", { kind: "custom" })
  await h.advance(0)
  assert.deepEqual(h.events().filter((b) => b.op === "waiting").map((b) => b.waiting), [{ kind: "custom" }])
})

test("a gate in a batch of tools names the tool that started last, the one it is preparing", async () => {
  const h = harness()
  await h.connect()
  h.emit("tool_execution_start", { toolCallId: "a", toolName: "read", args: { path: "notes.md" } })
  h.emit("tool_execution_start", { toolCallId: "b", toolName: "bash", args: { command: "rm -rf build" } })
  h.emit("ui_prompt_start", { kind: "select", title: "Allow?" })
  await h.advance(0)
  assert.deepEqual(h.events().filter((b) => b.op === "waiting").map((b) => b.waiting), [
    { kind: "select", title: "Allow?", tool: "bash", detail: '{"command":"rm -rf build"}' },
  ])
})

test("an unrelated dialog while one tool runs is still reported with that tool, as best effort", async () => {
  const h = harness()
  await h.connect()
  h.emit("tool_execution_start", { toolCallId: "a", toolName: "bash", args: { command: "make test" } })
  h.emit("ui_prompt_start", { kind: "input", title: "Bookmark name?" })
  await h.advance(0)
  assert.deepEqual(h.events().filter((b) => b.op === "waiting").map((b) => b.waiting), [
    { kind: "input", title: "Bookmark name?", tool: "bash", detail: '{"command":"make test"}' },
  ])
})

test("a long tool argument and a long reply are cut before they are reported", async () => {
  const h = harness()
  await h.connect()
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "text", text: "a".repeat(2_000) + "the end" }] } })
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "question", args: { question: "x".repeat(5_000) } })
  h.emit("ui_prompt_start", { kind: "custom" })
  await h.advance(0)
  const reported = h.events().find((b) => b.op === "waiting").waiting
  assert.ok((reported.detail as string).length <= 1_000)
  assert.ok((reported.detail as string).startsWith('{"question":"xxx'))
  assert.ok((reported.said as string).length <= 500)
  assert.ok((reported.said as string).endsWith("the end"))
})

test("a hello sent while a dialog is open carries what it waits for", async () => {
  const h = harness()
  await h.connect()
  h.emit("ui_prompt_start", { kind: "input", title: "Which database?" })
  await h.answerEvents()
  await h.advance(310_000)
  const hellos = h.events().filter((b) => b.op === "hello")
  assert.equal(hellos.length, 2)
  assert.equal(hellos[0].waiting, undefined)
  assert.deepEqual(hellos[1].waiting, { kind: "input", title: "Which database?" })
})

test("a command for another session is refused without acting", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "submit", id: "r1", expectedSession: "other", text: "x" }])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["sessionChanged"])
  assert.equal(h.sends.length, 0)
})

test("a key pressed just before dictation arrives holds it until the keyboard has been quiet for three seconds", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.advance(1_000)
  await h.deliver([h.submit("r1")])
  assert.equal(h.sends.length, 0)
  await h.advance(1_999)
  assert.equal(h.sends.length, 0)
  await h.advance(1)
  assert.equal(h.sends.length, 1)
})

test("a submission held for the keyboard is refused and never sent once the conversation is disconnected", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1")])
  await h.deliver([{ op: "quiet", id: "q1", expectedSession: "s1" }])
  await h.advance(6_000)
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().filter((b) => b.request === "r1").map((b) => b.reason).filter(Boolean), ["disconnected"])
})

test("a submission that arrives while the conversation is disconnected is refused", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "quiet", id: "q1", expectedSession: "s1" }])
  await h.deliver([h.submit("r1")])
  await h.advance(1_000)
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().filter((b) => b.request === "r1").map((b) => b.reason).filter(Boolean), ["disconnected"])
})

test("a submission held past the deadline the app gave it is refused as expired and never sent", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1", "run the tests", { expiresAt: h.now + 2_000 })])
  await h.advance(3_000)
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().filter((b) => b.request === "r1").map((b) => b.reason).filter(Boolean), ["expired"])
})

test("a submission that arrives after its deadline is refused as expired", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests", { expiresAt: h.now })])
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().filter((b) => b.request === "r1").map((b) => b.reason).filter(Boolean), ["expired"])
})

test("keys that keep coming extend the hold, but never past six seconds", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1")])
  await h.advance(2_000)
  await h.key()
  await h.advance(2_000)
  await h.key()
  await h.advance(1_999)
  assert.equal(h.sends.length, 0)
  await h.advance(1)
  assert.equal(h.sends.length, 1)
  assert.equal(h.now, 1_000_000 + 6_000)
})

test("a prompt typed during the hold refuses the dictation as typed since", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1", "x", { expectedPrompts: 0 })])
  await h.typed()
  await h.advance(3_000)
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["typedSince"])
})

test("a run starting during the hold steers the dictation into it", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1")])
  h.live.idle = false
  h.emit("agent_start")
  await h.advance(3_000)
  assert.equal(h.sends.length, 1)
  assert.deepEqual(h.sends[0].options, { deliverAs: "steer" })
})

test("a session replaced during the hold never submits", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1")])
  h.emit("session_shutdown", { reason: "new" })
  h.live.session = "s2"
  h.emit("session_start", { reason: "new" })
  await h.advance(3_000)
  assert.equal(h.sends.length, 0)
})

test("a turn that ends by being stopped is reported as aborted", async () => {
  const h = harness()
  await h.connect()
  h.emit("agent_start")
  await h.finished(true)
  const complete = h.events().find((b) => b.op === "turnComplete")
  assert.equal(complete.reason, "aborted")
  assert.equal(complete.session, "s1")
  assert.equal("answer" in complete, false)
})

test("a status from the app is shown after the connector's own name and an empty one clears it", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "status", id: "r1", expectedSession: "s1", text: "“api”" }, { op: "status", id: "r2", expectedSession: "s1", text: "" }])
  assert.deepEqual(h.statuses, ["keyscribe-dev: “api”", undefined])
})

test("losing the connection clears only the status this connector set, once", async () => {
  const h = harness()
  await h.connect()
  h.open("/poll")[0].answer(409)
  await h.settle()
  assert.deepEqual(h.statuses, [])
  await h.answerEvents()
  await h.deliver([{ op: "status", id: "r1", expectedSession: "s1", text: "“api”" }])
  h.open("/poll")[0].answer(409)
  await h.settle()
  assert.deepEqual(h.statuses, ["keyscribe-dev: “api”", undefined])
})

test("a focus runs only the named definition, outside its place it is refused, and it runs before expiry", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "focus", id: "r1", expectedSession: "s1", expiresAt: h.now + 3000, definition: "cmux" }])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["notInPlace"])
  h.env.CMUX_SURFACE_ID = "surface-9"
  await h.answerEvents()
  await h.deliver([{ op: "focus", id: "r2", expectedSession: "s1", expiresAt: h.now - 1, definition: "cmux" }])
  assert.deepEqual(h.replies().filter((b) => b.request === "r2").map((b) => b.reason).filter(Boolean), ["expired"])
  await h.answerEvents()
  await h.deliver([{ op: "focus", id: "r3", expectedSession: "s1", expiresAt: h.now + 3000, definition: "cmux" }])
  assert.deepEqual(h.execs, [["/usr/bin/env", "cmux", "focus-panel", "--panel", "surface-9"]])
  assert.deepEqual(h.replies().filter((b) => b.request === "r3").map((b) => b.op), ["ack", "focused"])
  h.execCode = 1
  await h.answerEvents()
  await h.deliver([{ op: "focus", id: "r4", expectedSession: "s1", expiresAt: h.now + 3000, definition: "cmux" }])
  assert.deepEqual(h.replies().filter((b) => b.request === "r4").map((b) => b.reason).filter(Boolean), ["focusFailed"])
})

test("a focus definition is substituted whole, never by a shell, and never from a value that reads as an option", async () => {
  const h = harness()
  await h.connect()
  h.env.MUX_PANE = `pane "1" $(touch /tmp/x); rm`
  h.env.ZELLIJ_PANE_ID = "7"
  for (const [id, definition] of [["r1", undefined], ["r2", "unknown"], ["r3", "stray"], ["r4", "relative"]] as const) {
    await h.deliver([{ op: "focus", id, expectedSession: "s1", expiresAt: h.now + 3000, definition }])
    await h.answerEvents()
  }
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["unknownFocus", "unknownFocus", "unknownFocus", "unknownFocus"])
  assert.deepEqual(h.execs, [])
  await h.deliver([{ op: "focus", id: "r5", expectedSession: "s1", expiresAt: h.now + 3000, definition: "mux" }])
  assert.deepEqual(h.execs, [["/opt/mux/bin/mux", "focus", "--pane={MUX_PANE}", `pane "1" $(touch /tmp/x); rm`]])
  await h.answerEvents()
  h.env.MUX_PANE = "-rf"
  await h.deliver([{ op: "focus", id: "r6", expectedSession: "s1", expiresAt: h.now + 3000, definition: "mux" }])
  assert.deepEqual(h.replies().filter((b) => b.request === "r6").map((b) => b.reason).filter(Boolean), ["unsafeValue"])
  assert.equal(h.execs.length, 1)
})

test("a command the connector does not offer is refused", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "rewind", id: "r1", expectedSession: "s1", text: "x" }])
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["unsupported"])
})

test("a renamed session reports its name, and a cleared name reports empty", async () => {
  const h = harness()
  await h.connect()
  h.emit("session_info_changed", { name: "backend" })
  h.emit("session_info_changed", { name: undefined })
  await h.settle()
  assert.deepEqual(h.events().filter((b) => b.op === "title").map((b) => b.text), ["backend", ""])
})

test("a replaced session drops the old one's events, refuses its commands and says hello for the new id", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1")])
  const poll = h.open("/poll")[0]
  h.emit("session_shutdown", { reason: "new" })
  await h.settle()
  assert.equal(poll.cancelled, true)
  h.live.session = "s2"
  h.live.idle = true
  await h.start("new")
  const hellos = h.events().filter((b) => b.op === "hello")
  assert.equal(hellos.length, 2)
  assert.equal(hellos[1].session, "s2")
  assert.equal(hellos[1].gap, false)
  assert.equal(hellos[1].prompts, 0)
  assert.equal(h.events().filter((b) => b.op === "submitted").length, 0)
  assert.equal(h.open("/poll").length, 1)
  assert.equal(h.open("/poll")[0].body.session, "s2")
})

test("a quit ends the connector's requests without acting on anything later", async () => {
  const h = harness()
  await h.connect()
  const poll = h.open("/poll")[0]
  h.emit("session_shutdown", { reason: "quit" })
  await h.settle()
  assert.equal(poll.cancelled, true)
  h.emit("agent_start")
  await h.advance(60_000)
  assert.equal(h.open().length, 0)
  assert.deepEqual(h.ops(), ["hello"])
})

test("a typed prompt overtaking queued dictation holds it", async () => {
  const h = harness()
  await h.connect()
  await h.typed()
  await h.deliver([h.submit("r1", "x", { expectedPrompts: 0 })])
  assert.equal(h.sends.length, 0)
  assert.deepEqual(h.replies().map((b) => b.reason).filter(Boolean), ["typedSince"])
})

test("without readiness nothing connects, and only a local check runs about every ten seconds", async () => {
  const h = harness()
  h.ready(undefined)
  await h.start()
  assert.equal(h.requests.length, 0)
  const before = h.readyChecks()
  await h.advance(10_000)
  assert.equal(h.readyChecks(), before + 1)
  await h.advance(10_000)
  assert.equal(h.readyChecks(), before + 2)
  assert.equal(h.requests.length, 0)
})

test("without readiness a connector that can watch the app's folder reads nothing until the folder changes", async () => {
  const h = harness({ watches: true })
  h.ready(undefined)
  await h.start()
  const before = h.readyChecks()
  await h.advance(60_000)
  assert.equal(h.readyChecks(), before)
  assert.equal(h.requests.length, 0)
  const open = h.watching.filter((w) => !w.closed)
  assert.deepEqual(open.map((w) => w.folder), ["/tmp"])
  h.ready("L1")
  open[0].fn()
  await h.settle()
  assert.equal(h.open("/event")[0]?.body.op, "hello")
})

test("the app starting just as the watch is set up is seen by the read that follows it", async () => {
  const h = harness({ watches: true })
  h.ready(undefined)
  h.onWatch = () => h.ready("L1")
  await h.start()
  await h.settle()
  assert.equal(h.open("/event")[0]?.body.op, "hello")
})

test("a watch that breaks falls back to the ten-second check for good, without spinning", async () => {
  const h = harness({ watches: true })
  h.ready(undefined)
  await h.start()
  const before = h.readyChecks()
  h.watching.filter((w) => !w.closed)[0].broken()
  await h.settle()
  const after = h.readyChecks()
  assert.ok(after - before <= 2)
  await h.advance(10_000)
  assert.equal(h.readyChecks(), after + 1)
  assert.equal(h.watching.filter((w) => !w.closed).length, 0)
})

test("a refused launch is never tried again until the bridge relaunches", async () => {
  const h = harness()
  await h.start()
  h.open("/event")[0].refuse()
  await h.settle()
  await h.advance(60_000)
  assert.equal(h.requests.length, 1)
  h.ready("L2")
  await h.advance(10_000)
  assert.equal(h.requests.length, 2)
  assert.equal(h.requests[1].body.op, "hello")
})

test("a bridge that keeps hanging is retried with growing waits", async () => {
  const h = harness()
  await h.start()
  const first = h.open("/event")[0]
  await h.advance(2_000)
  assert.equal(first.cancelled, true)
  assert.equal(h.requests.length, 1)
  await h.advance(20_000)
  assert.equal(h.requests.length, 1)
  await h.advance(20_000)
  assert.equal(h.requests.length, 2)
  await h.advance(2_000)
  await h.advance(50_000)
  assert.equal(h.requests.length, 2)
  await h.advance(30_000)
  assert.equal(h.requests.length, 3)
})

test("a cooldown that ends between the ten-second checks retries at once", async () => {
  const random = Math.random
  Math.random = () => 0.5
  try {
    const h = harness()
    await h.start()
    await h.advance(2_000)
    assert.equal(h.requests.length, 1)
    await h.advance(33_000)
    assert.equal(h.requests.length, 1)
    await h.advance(1_000)
    assert.equal(h.requests.length, 2)
    assert.equal(h.requests[1].body.op, "hello")
  } finally {
    Math.random = random
  }
})

test("the real host still reports the app's ready file after the watched folder is removed and made again", async () => {
  const folder = join(mkdtempSync(join(tmpdir(), "ks-watch-")), "app")
  mkdirSync(folder)
  let changes = 0
  let broken = false
  const unwatch = nodeHost({} as any).watch!(folder, () => { changes += 1 }, () => { broken = true })
  try {
    assert.ok(unwatch)
    rmSync(folder, { recursive: true })
    await new Promise((r) => setTimeout(r, 300))
    mkdirSync(folder)
    await new Promise((r) => setTimeout(r, 300))
    const before = changes
    writeFileSync(join(folder, "ready.json"), "{}")
    for (let i = 0; i < 40 && changes === before && !broken; i++) await new Promise((r) => setTimeout(r, 50))
    assert.ok(changes > before || broken, "neither a change nor a broken watch was reported")
  } finally {
    unwatch?.()
    rmSync(dirname(folder), { recursive: true, force: true })
  }
})

test("a relaunched bridge ends the wait", async () => {
  const h = harness()
  await h.start()
  await h.advance(2_000)
  assert.equal(h.requests.length, 1)
  h.ready("L2")
  await h.advance(10_000)
  assert.equal(h.requests.length, 2)
})

test("a rejected hello goes quiet until a new session", async () => {
  const h = harness()
  await h.start()
  h.open("/event")[0].answer(400)
  await h.settle()
  await h.advance(120_000)
  assert.equal(h.requests.length, 1)
  assert.equal(h.readyChecks(), 1)
  h.emit("session_shutdown", { reason: "new" })
  h.live.session = "s2"
  await h.start("new")
  assert.equal(h.requests.length, 2)
})

test("a bridge on another protocol is left alone", async () => {
  const h = harness()
  h.ready("L1", 3)
  await h.start()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
})

test("a connector without its settings stays dormant", async () => {
  const h = harness({ configPath: null })
  await h.start()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
})

test("a poll past its deadline reconnects, and the connection is said hello again", async () => {
  const h = harness()
  await h.connect()
  const poll = h.open("/poll")[0]
  await h.advance(310_000)
  assert.equal(poll.cancelled, true)
  const hellos = h.events().filter((b) => b.op === "hello")
  assert.equal(hellos.length, 2)
  assert.notEqual(hellos[1].connection, hellos[0].connection)
  assert.equal(h.open("/poll").length, 1)
})

test("a command being prepared when the connection is lost never acts", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit("r1")])
  h.open("/poll")[0].answer(409)
  await h.advance(3_000)
  assert.equal(h.sends.length, 0)
})

test("a command repeated on the same connection runs once", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1"), h.submit("r1")])
  assert.equal(h.sends.length, 1)
  assert.deepEqual(h.replies().map((b) => b.op), ["ack", "ack"])
})

test("every event, reply and poll carries the connection its hello opened", async () => {
  const h = harness()
  const hello = await h.connect()
  await h.typed()
  const poll = h.open("/poll")[0]
  assert.equal(poll.body.connection, hello.connection)
  assert.equal(poll.body.instance, hello.instance)
  const typed = h.events().find((b) => b.op === "typed")
  assert.equal(typed.connection, hello.connection)
  assert.equal(typed.instance, hello.instance)
})

test("a hello names the installation the connector was loaded from", async () => {
  const h = harness({ loadedFrom: "I1" })
  const hello = await h.connect()
  assert.equal(hello.installation, "I1")
})

test("a retire ends the connector for good without answering, even for a new session", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "retire", id: "retire" }])
  await h.advance(60_000)
  assert.equal(h.open().length, 0)
  h.emit("session_shutdown", { reason: "new" })
  h.live.session = "s2"
  await h.start("new")
  await h.advance(60_000)
  assert.deepEqual(h.ops(), ["hello"])
})

test("a retire during a run stops the stale-turn watch, and a later run never starts one", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  assert.ok(h.timers.length > 0)
  await h.deliver([{ op: "retire", id: "retire" }])
  await h.settle()
  h.emit("agent_start")
  await h.advance(60_000)
  assert.equal(h.timers.length, 0)
  assert.equal(h.events().filter((b) => b.op === "turnComplete").length, 0)
})

test("a connector whose installation was replaced never reconnects", async () => {
  const h = harness({ loadedFrom: "I0" })
  await h.start()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
})

test("a hello refused as another installation retires the connector", async () => {
  const h = harness()
  await h.start()
  h.open("/event")[0].answer(403)
  await h.settle()
  await h.advance(120_000)
  assert.equal(h.requests.length, 1)
  h.emit("session_shutdown", { reason: "new" })
  h.live.session = "s2"
  await h.start("new")
  await h.advance(60_000)
  assert.equal(h.requests.length, 1)
})

test("no handler waits on the bridge", async () => {
  const h = harness()
  await h.connect()
  const started = Date.now()
  h.emit("input", { text: "x", source: "interactive" })
  h.emit("agent_start")
  h.emit("agent_settled", { aborted: false })
  h.emit("session_info_changed", { name: "n" })
  assert.ok(Date.now() - started < 50)
  await h.settle()
  assert.deepEqual(h.ops(), ["hello", "typed", "turnStarted", "turnComplete", "title"])
})

test("a hello answered quietly keeps polling but sends nothing about the conversation", async () => {
  const h = harness()
  h.live.name = "secret plan"
  await h.start()
  h.open("/event")[0].answer(200, JSON.stringify({ ok: true, quiet: true }))
  await h.settle()
  assert.equal(h.open("/poll").length, 1)
  h.emit("input", { text: "x", source: "interactive" })
  h.live.idle = false
  h.emit("agent_start")
  h.emit("session_info_changed", { name: "renamed" })
  await h.settle()
  assert.deepEqual(h.ops(), ["hello"])
})

test("a quiet command stops observing and admit says a full hello again", async () => {
  const h = harness()
  h.live.name = "frontend"
  h.env.ZELLIJ_PANE_ID = "7"
  await h.connect()
  await h.deliver([{ op: "quiet", id: "q1", expectedSession: "s1" }])
  await h.answerEvents()
  const before = h.events().length
  h.emit("input", { text: "x", source: "interactive" })
  await h.settle()
  assert.equal(h.events().length, before)
  await h.deliver([{ op: "admit", id: "a1", expectedSession: "s1" }])
  await h.advance(1_000)
  const hellos = h.events().filter((b) => b.op === "hello")
  assert.equal(hellos.length, 2)
  assert.equal(hellos[1].title, "frontend")
  assert.deepEqual(hellos[1].environment, { ZELLIJ_PANE_ID: "7" })
  h.emit("input", { text: "y", source: "interactive" })
  await h.answerEvents()
  assert.ok(h.events().some((b) => b.op === "typed"))
})

test("while quiet a hello again carries only who the connector is", async () => {
  const h = harness()
  h.live.name = "secret plan"
  h.env.ZELLIJ_PANE_ID = "7"
  await h.connect()
  await h.deliver([{ op: "quiet", id: "q1", expectedSession: "s1" }])
  await h.answerEvents()
  h.open("/poll")[0].answer(409)
  await h.advance(1_000)
  const again = h.events().filter((b) => b.op === "hello")[1]
  assert.ok(again, "no second hello")
  assert.equal(again.title, undefined)
  assert.equal(again.prompts, undefined)
  assert.equal(again.environment, undefined)
  assert.equal(again.waiting, undefined)
  assert.equal(again.session, "s1")
  assert.equal(again.installation, "I1")
})

async function askedToReadAloud(h: any, call: Promise<any>, answer: string | null) {
  await h.settle()
  const notify = h.open("/event").find((r: any) => r.body.op === "notify")
  assert.ok(notify, "no notify was sent")
  if (answer !== null) notify.answer(200, answer)
  await h.settle()
  return { body: notify.body, result: await call }
}

test("hello names the turn it is running so the app can keep waiting for its reply", async () => {
  const h = harness()
  await h.connect()
  h.live.idle = false
  h.emit("agent_start")
  await h.settle()
  h.open("/poll")[0].answer(409)
  await h.settle()
  const again = h.events().filter((b) => b.op === "hello").slice(-1)[0]
  assert.equal(again.turn, h.turn(1))
})

test("the read-aloud tool asks for the running turn and tells the model only what the app answered", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  h.live.idle = false
  h.emit("agent_start")
  await h.settle()
  await h.answerEvents()
  assert.equal(h.tools.length, 1)
  assert.equal(h.tools[0].name, "keyscribe_dev_tell_me_when_done")
  assert.notEqual(readAloudToolName("keyscribe"), readAloudToolName("keyscribe-dev"))
  const cases: Array<[string, RegExp]> = [
    ['{"ok":true,"spoken":true}', /will report your final reply/],
    ['{"ok":true,"spoken":false}', /Read Agent Replies Aloud is off/],
    ['{"ok":true,"quiet":true}', /disconnected/],
  ]
  for (const [answer, said] of cases) {
    const { body, result } = await askedToReadAloud(h, h.tools[0].execute("call", {}), answer)
    assert.deepEqual({ op: body.op, session: body.session, turn: body.turn, on: body.on }, { op: "notify", session: "s1", turn: h.turn(1), on: true })
    assert.match(result.content[0].text, said)
  }
})

test("a read-aloud request the app never answers promises nothing", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  const call = h.tools[0].execute("call", {})
  await h.settle()
  await h.advance(5_000)
  assert.match((await call).content[0].text, /didn\u2019t confirm the request, so the reply may not be reported\. Tell the user\.$/)
})

test("a read-aloud command the app never answers says the reply may not come", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  const run = h.runCommand("keyscribe-dev", "")
  await h.settle()
  await h.advance(5_000)
  await run
  assert.match(h.notes[h.notes.length - 1], /didn\u2019t confirm the request, so you may not get this reply\.$/)
})

test("the command covers the running turn, the next one when idle, and cancels", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  const first = await askedToReadAloud(h, h.runCommand("keyscribe-dev", ""), '{"ok":true,"spoken":true}')
  assert.equal(first.body.turn, "")
  assert.equal(first.body.on, true)
  assert.match(h.notes[0], /your next reply/)

  h.live.idle = false
  h.emit("agent_start")
  await h.settle()
  await h.answerEvents()
  const second = await askedToReadAloud(h, h.runCommand("keyscribe-dev", ""), '{"ok":true,"spoken":true}')
  assert.equal(second.body.turn, h.turn(1))
  assert.match(h.notes[1], /the result of this work/)

  const third = await askedToReadAloud(h, h.runCommand("keyscribe-dev", "cancel"), '{"ok":true,"spoken":true}')
  assert.equal(third.body.on, false)
  assert.match(h.notes[2], /won\u2019t report this reply/)
})

test("a reloaded connector numbers its turns apart from the one before, so a request never carries over to other work", async () => {
  const first = harness()
  await first.connect()
  const second = harness()
  await second.connect()
  assert.notEqual(first.turn(1), second.turn(1))
})

test("a read-aloud request that timed out behind other events is never delivered late", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  await h.typed("one")
  await h.typed("two")
  await h.typed("three")
  const call = h.tools[0].execute("call", {})
  for (let i = 0; i < 4; i++) {
    await h.advance(1500)
    if (h.open("/event").length) h.open("/event")[0].answer(200)
    await h.settle()
  }
  assert.match((await call).content[0].text, /didn’t confirm the request/)
  await h.answerEvents()
  assert.ok(!h.ops().includes("notify"))
})

test("a reply to the dictation that started the run says it came after that dictation, even with context an extension added", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "Yes to all four.", { expectedPrompts: 0 })])
  await h.accepted()
  h.emit("message_start", { message: { role: "custom", content: "Project notes for the agent." } })
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "text", text: "Done." }] } })
  await h.finished()
  await h.answerEvents()
  const [done] = h.events().filter((b) => b.op === "turnComplete")
  assert.equal(done.from, undefined)
  assert.equal(done.prompt, digest("Yes to all four."))
})

test("a message an extension adds once the agent has answered a dictation ends that dictation's turn with its answer at once, and the reply to it is a turn of its own from someone else", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "Yes to all four.", { expectedPrompts: 0 })])
  await h.accepted()
  h.emit("message_end", { message: { role: "assistant", stopReason: "toolUse", content: [{ type: "toolCall", name: "bash" }] } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "All four are in." }] } })
  h.emit("message_start", { message: { role: "custom", content: "Found a race in the cache." } })
  await h.settle()
  await h.answerEvents()
  assert.deepEqual(
    h.events().filter((b) => b.op === "turnComplete").map((b) => [b.answer, b.prompt, b.from]),
    [["All four are in.", digest("Yes to all four."), undefined]],
  )
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "The disk writer is a software update." }] } })
  await h.finished()
  await h.answerEvents()
  assert.deepEqual(
    h.events().filter((b) => b.op === "turnStarted" || b.op === "turnComplete").map((b) => [b.op, b.turn, b.answer, b.prompt, b.from]),
    [
      ["turnStarted", h.turn(1), undefined, undefined, undefined],
      ["turnComplete", undefined, "All four are in.", digest("Yes to all four."), undefined],
      ["turnStarted", h.turn(2), undefined, undefined, undefined],
      ["turnComplete", undefined, "The disk writer is a software update.", undefined, "other"],
    ],
  )
})

test("a message added while the agent is still working on a dictation keeps one turn whose reply names no request", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "Yes to all four.", { expectedPrompts: 0 })])
  await h.accepted()
  h.emit("message_end", { message: { role: "assistant", stopReason: "toolUse", content: [{ type: "text", text: "Checking." }, { type: "toolCall", name: "bash" }] } })
  h.emit("message_start", { message: { role: "custom", content: "Found a race in the cache." } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "error", content: [] } })
  h.emit("message_start", { message: { role: "custom", content: "Retry." } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "All four are in." }] } })
  await h.finished()
  await h.answerEvents()
  assert.equal(h.ops().filter((op) => op === "turnStarted").length, 1)
  assert.deepEqual(
    h.events().filter((b) => b.op === "turnComplete").map((b) => [b.answer, b.prompt, b.from]),
    [["All four are in.", undefined, undefined]],
  )
})

test("a message typed into the agent once it has answered a dictation ends that dictation's turn, and the reply to it names the typed prompt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "Yes to all four.", { expectedPrompts: 0 })])
  await h.accepted()
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "All four are in." }] } })
  h.emit("message_start", { message: { role: "user", content: "now the docs" } })
  h.emit("message_end", { message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "Docs updated." }] } })
  await h.finished()
  await h.answerEvents()
  assert.deepEqual(
    h.events().filter((b) => b.op === "turnComplete").map((b) => [b.answer, b.prompt, b.from]),
    [["All four are in.", digest("Yes to all four."), undefined], ["Docs updated.", digest("now the docs"), undefined]],
  )
})

test("a reply after a message added once the agent had answered is from someone else, and one typed or sent by another extension names its prompt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "Yes to all four.", { expectedPrompts: 0 })])
  await h.accepted()
  h.emit("message_end", { message: { role: "assistant", content: [{ type: "text", text: "Done." }] } })
  h.emit("message_start", { message: { role: "custom", content: "Found a race in the cache." } })
  await h.finished()
  h.live.idle = false
  h.emit("input", { text: "now the docs", source: "interactive" })
  h.emit("agent_start")
  h.emit("message_start", { message: { role: "user", content: "now the docs" } })
  await h.finished()
  h.live.idle = false
  h.emit("input", { text: "from a bridge", source: "extension" })
  h.emit("agent_start")
  h.emit("message_start", { message: { role: "user", content: "from a bridge" } })
  await h.finished()
  await h.answerEvents()
  assert.deepEqual(
    h.events().filter((b) => b.op === "turnComplete").map((b) => [b.from, b.prompt]),
    [[undefined, digest("Yes to all four.")], ["other", undefined], [undefined, digest("now the docs")], [undefined, digest("from a bridge")]],
  )
})
