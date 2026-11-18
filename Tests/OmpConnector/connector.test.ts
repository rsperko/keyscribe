import assert from "node:assert/strict"
import { test } from "node:test"
import { connector, ompConnector, type Host, type Response } from "../../Sources/KeyScribe/Resources/PiConnector/index.ts"

type Request = {
  path: string
  body: any
  settled: boolean
  answer: (status: number, text?: string) => void
}

type Options = { mode?: string; host?: "omp" | "pi" | "piWithItsPackage" | "ompWithoutItsPackage"; load?: "omp" | "pi" }

function harness(options: Options = {}) {
  const handlers = new Map<string, Array<(event: any, ctx: any) => unknown>>()
  const requests: Request[] = []
  const sends: Array<{ text: string; content: any; options: any; settle: () => void; drop: (error: Error) => void }> = []
  const images: Record<string, string> = {}
  const statuses: Array<string | undefined> = []
  const files: Record<string, string | undefined> = {
    "/plugin/keyscribe.json": JSON.stringify({
      protocol: 2, socketPath: "/tmp/ks.sock", tokenPath: "/tmp/ks-token", readyPath: "/tmp/ks-ready.json", installation: "I1",
      plugin: "keyscribe-dev", environmentKeys: [], focusDefinitions: [],
    }),
    "/tmp/ks-token": "secret\n",
    "/tmp/ks-ready.json": JSON.stringify({ launch: "L1", protocol: 2 }),
  }
  const timers: Array<{ at: number; fn: () => void; id: number }> = []
  let timerId = 0
  let now = 1_000_000
  const live = {
    session: "s1", name: undefined as string | undefined, titleSource: undefined as string | undefined, idle: true, editor: "",
    cwd: "/work", mode: options.mode ?? "tui", model: { id: "m" } as { id: string } | undefined,
  }
  let keyHandler: ((data: string) => unknown) | null = null
  let autoEvents = false
  let busySendsQueue = true

  const host: Host = {
    pid: 4242,
    now: () => now,
    env: () => undefined,
    read: async (path) => {
      const text = files[path]
      if (text === undefined) throw new Error("ENOENT")
      return text
    },
    readBase64: async (path) => {
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
    exec: async () => ({ code: 0 }),
    post: (socketPath, path, body) => {
      let resolve: (r: Response) => void = () => {}
      let reject: (e: Error) => void = () => {}
      const response = new Promise<Response>((res, rej) => { resolve = res; reject = rej })
      const request: Request = {
        path, body: JSON.parse(body), settled: false,
        answer: (status, text = "{}") => {
          request.settled = true
          resolve({ status, ok: status >= 200 && status < 300, text })
        },
      }
      requests.push(request)
      if (autoEvents && path === "/event") queueMicrotask(() => { if (!request.settled) request.answer(200) })
      return {
        response,
        cancel: () => {
          if (request.settled) return
          request.settled = true
          reject(new Error("cancelled"))
        },
      }
    },
  }

  const ctx = {
    get mode() { return live.mode },
    get cwd() { return live.cwd },
    sessionManager: {
      getSessionId: () => live.session,
      getCwd: () => live.cwd,
      get titleSource() { return live.titleSource },
    },
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
  const pi: any = {
    registerTool: (tool: any) => { tools.push(tool) },
    registerCommand: (name: string, options: any) => { commands.set(name, options) },
    on: (event: string, handler: (event: any, ctx: any) => unknown) => {
      handlers.set(event, [...(handlers.get(event) ?? []), handler])
      return () => {}
    },
    sendUserMessage: (content: any, sendOptions: any) => {
      const text = typeof content === "string" ? content : content.filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n")
      let settle: () => void = () => {}
      let drop: (error: Error) => void = () => {}
      const done = new Promise<void>((resolve, reject) => { settle = resolve; drop = reject })
      sends.push({ text, content, options: sendOptions, settle, drop })
      if (!(sendOptions && sendOptions.deliverAs) || !busySendsQueue) return done
      settle()
      return done
    },
    getSessionName: () => live.name,
    exec: async () => ({ code: 0 }),
  }
  const shape = options.host ?? "omp"
  if (shape === "omp" || shape === "ompWithoutItsPackage") pi.arktype = {}
  if (shape === "omp") pi.pi = { VERSION: "18.22.2", getAgentDir: () => "/Users/a/.omp/agent" }
  if (shape === "piWithItsPackage") pi.pi = { VERSION: "1.5.0", getAgentDir: () => "/Users/a/.pi/agent" }

  const settings = { configPath: "/plugin/keyscribe.json", loadedFrom: null }
  if ((options.load ?? "omp") === "omp") ompConnector(pi, host, settings)
  else connector(pi, host, settings)

  const emit = (event: string, payload: any = {}) =>
    (handlers.get(event) ?? []).map((handler) => handler({ type: event, ...payload }, ctx))
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

  async function start() {
    emit("session_start")
    await settle()
  }

  async function connect() {
    await start()
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

  const user = (text: string) => ({ message: { role: "user", content: [{ type: "text", text }] } })
  const assistant = (text: string, stopReason = "stop") => ({ message: { role: "assistant", stopReason, content: [{ type: "text", text }] } })

  const typed = async (text = "typed by me") => {
    emit("input", { text, source: "interactive" })
    await settle()
  }
  const runStarts = async () => {
    live.idle = false
    emit("before_agent_start", { reason: "prompt" })
    emit("agent_start")
    await settle()
  }
  const taken = async () => {
    await runStarts()
    emit("message_start", user(sends[sends.length - 1].text))
    await settle()
  }
  const runEnds = async (extra: Record<string, unknown> = {}) => {
    live.idle = true
    emit("session_stop", { stop_hook_active: false })
    emit("agent_end", { messages: [], ...extra })
    await settle()
  }
  const pauses = async (awaitingAsyncWork: boolean) => {
    live.idle = awaitingAsyncWork
    emit("agent_end", { messages: [], willContinue: true, ...(awaitingAsyncWork ? { awaitingAsyncWork: true } : {}) })
    await settle()
  }
  const key = async () => {
    assert.ok(keyHandler, "no terminal input handler")
    keyHandler("x")
    await settle()
  }
  const submit = (id = "r1", text = "run the tests", extra: Record<string, unknown> = {}) => ({ op: "submit", id, expectedSession: live.session, text, expiresAt: now + 8_000, ...extra })
  const turn = (n: number) => `${events().find((b) => b.op === "hello").instance}.${n}`
  const runCommand = (name: string, args: string) => commands.get(name).handler(args, commandCtx)

  return {
    requests, sends, statuses, files, images, live, tools, commands, notes, runCommand,
    set busySendsQueue(value: boolean) { busySendsQueue = value },
    set autoEvents(value: boolean) { autoEvents = value },
    get timersMade() { return timerId },
    get now() { return now },
    turn, emit, settle, advance, open, events, ops, replies, start, connect, deliver, typed, runStarts, taken, runEnds, pauses, key,
    submit, user, assistant,
  }
}

test("outside the terminal UI the connector does nothing", async () => {
  for (const mode of ["rpc", "print", "json", "acp"]) {
    const h = harness({ mode })
    await h.start()
    await h.advance(60_000)
    assert.equal(h.requests.length, 0, mode)
  }
})

test("a subagent's own instance, started in print mode, never connects or reports", async () => {
  const h = harness({ mode: "print" })
  await h.start()
  await h.runStarts()
  await h.runEnds()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
})

test("the omp connector loaded by another host stays inert", async () => {
  const h = harness({ host: "pi", load: "omp" })
  await h.start()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
  assert.equal(h.tools.length, 0)
})

test("a Pi that exposes its own package to extensions is still Pi: the Pi connector says hello and omp's stays inert", async () => {
  const pi = harness({ host: "piWithItsPackage", load: "pi" })
  const hello = await pi.connect()
  assert.equal(hello.agent, "pi")
  const omp = harness({ host: "piWithItsPackage", load: "omp" })
  await omp.start()
  await omp.advance(60_000)
  assert.equal(omp.requests.length, 0)
  assert.equal(omp.tools.length, 0)
})

test("an omp that does not expose its package still runs omp's adapter, with no agent version", async () => {
  const h = harness({ host: "ompWithoutItsPackage" })
  const hello = await h.connect()
  assert.equal(hello.agent, "omp")
  assert.equal(hello.agentVersion, "")
})

test("the Pi connector loaded by omp, from a folder they share, stays inert", async () => {
  const h = harness({ host: "omp", load: "pi" })
  await h.start()
  await h.advance(60_000)
  assert.equal(h.requests.length, 0)
  assert.equal(h.tools.length, 0)
})

test("hello names omp, its version and what it offers", async () => {
  const h = harness()
  const hello = await h.connect()
  assert.equal(hello.agent, "omp")
  assert.equal(hello.agentVersion, "18.22.2")
  assert.equal(hello.installation, "I1")
  assert.equal(hello.session, "s1")
  assert.equal(hello.cwd, "/work")
  assert.deepEqual(hello.features, ["focus", "focusDefinitions", "label", "readiness", "notify", "images", "check", "steer", "merge"])
  assert.equal(hello.idle, true)
})

test("a session omp starts says hello as resuming, since omp does not say whether it is new", async () => {
  const h = harness()
  const hello = await h.connect()
  assert.equal(hello.gap, true)
})

test("a name the user gave is the title; a generated one never is", async () => {
  const named = harness()
  named.live.name = "frontend"
  named.live.titleSource = "user"
  assert.equal((await named.connect()).title, "frontend")
  const generated = harness()
  generated.live.name = "Fix retry queue dropping jobs"
  generated.live.titleSource = "auto"
  assert.equal("title" in (await generated.connect()), false)
})

test("a rename has no event in omp, so an idle conversation's new name is reported when the poll next returns, once", async () => {
  const h = harness()
  await h.connect()
  h.live.name = "backend"
  h.live.titleSource = "user"
  await h.deliver([])
  assert.deepEqual(h.events().filter((b) => b.op === "title").map((b) => b.text), ["backend"])
  await h.deliver([])
  await h.deliver([])
  assert.deepEqual(h.events().filter((b) => b.op === "title").map((b) => b.text), ["backend"])
})

test("a rename the user types lands after omp's input event, so the name is read again a moment later", async () => {
  const h = harness()
  await h.connect()
  await h.typed("/rename backend")
  h.live.name = "backend"
  h.live.titleSource = "user"
  assert.equal(h.events().filter((b) => b.op === "title").length, 0)
  await h.advance(3_000)
  assert.deepEqual(h.events().filter((b) => b.op === "title").map((b) => b.text), ["backend"])
})

test("a generated title is never reported when the poll returns, and losing a user name there reports it cleared", async () => {
  const h = harness()
  await h.connect()
  h.live.name = "Auto title"
  h.live.titleSource = "auto"
  await h.deliver([])
  assert.equal(h.events().filter((b) => b.op === "title").length, 0)
  h.live.name = "backend"
  h.live.titleSource = "user"
  await h.deliver([])
  h.live.name = "Auto title"
  h.live.titleSource = "auto"
  await h.deliver([])
  assert.deepEqual(h.events().filter((b) => b.op === "title").map((b) => b.text), ["backend", ""])
})

test("a retired connector reads no name after typing", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([{ op: "retire", id: "x" }])
  const before = h.requests.length
  await h.typed("/rename backend")
  h.live.name = "backend"
  h.live.titleSource = "user"
  await h.advance(30_000)
  assert.equal(h.requests.length, before)
})

test("Pi reports a rename from its own event, never from a poll returning", async () => {
  const h = harness({ host: "pi", load: "pi" })
  await h.connect()
  h.live.name = "backend"
  await h.deliver([])
  assert.equal(h.events().filter((b) => b.op === "title").length, 0)
})

test("a generated title replacing nothing is never reported, and losing a user name reports it cleared", async () => {
  const h = harness()
  h.live.name = "backend"
  h.live.titleSource = "user"
  await h.connect()
  h.live.name = "Auto title"
  h.live.titleSource = "auto"
  await h.typed()
  assert.deepEqual(h.events().filter((b) => b.op === "title").map((b) => b.text), [""])
})

test("dictation to an idle omp is sent with no delivery mode, since a follow-up would wait for a run that never comes", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 1)
  assert.deepEqual(h.sends[0].options, {})
  assert.ok(h.sends[0].text.startsWith("run the tests"))
})

test("omp fires no input event for the connector's message, so its own user message is the receipt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit()])
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 0)
  await h.taken()
  const submitted = h.replies().find((b) => b.op === "submitted")
  assert.equal(submitted?.request, "r1")
  assert.equal(submitted?.turn, h.turn(1))
})

test("an idle send whose promise resolves only when the run ends is still confirmed at its message", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit()])
  await h.taken()
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 1)
  h.sends[0].settle()
  await h.runEnds()
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 1)
})

test("a user message without the connector's mark is no receipt", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit()])
  await h.runStarts()
  h.emit("message_start", h.user("run the tests"))
  await h.settle()
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 0)
})

test("a clipboard image goes to omp with the words that name its file, at idle and as a steer", async () => {
  const h = harness()
  await h.connect()
  h.images["/clip/shot.png"] = "UE5H"
  h.images["/clip/other.PNG"] = "SlBH"
  await h.deliver([h.submit("r1", "look at /clip/shot.png and /clip/other.PNG", { images: ["/clip/shot.png", "/clip/other.PNG"] })])
  assert.equal(h.sends.length, 1)
  assert.deepEqual(h.sends[0].options, {})
  const [words, ...attached] = h.sends[0].content
  assert.equal(words.type, "text")
  assert.ok(words.text.startsWith("look at /clip/shot.png and /clip/other.PNG"))
  assert.deepEqual(attached, [
    { type: "image", data: "UE5H", mimeType: "image/png" },
    { type: "image", data: "SlBH", mimeType: "image/png" },
  ])
  await h.taken()
  await h.deliver([h.submit("r2", "and /clip/shot.png", { images: ["/clip/shot.png"] })])
  assert.equal(h.sends.length, 2)
  assert.deepEqual(h.sends[1].options, { deliverAs: "steer" })
  assert.deepEqual(h.sends[1].content.slice(1), [{ type: "image", data: "UE5H", mimeType: "image/png" }])
})

test("a clipboard image sent while an approval is open goes with the words as an aside", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.images["/clip/shot.png"] = "UE5H"
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "bash", args: { command: "ls" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "bash" })
  await h.settle()
  await h.deliver([h.submit("r1", "look at /clip/shot.png", { images: ["/clip/shot.png"] })])
  assert.deepEqual(h.sends[0].options, { deliverAs: "aside" })
  assert.deepEqual(h.sends[0].content.slice(1), [{ type: "image", data: "UE5H", mimeType: "image/png" }])
})

test("an image omp's connector cannot read, or that is not a PNG, leaves only the words naming its file", async () => {
  const h = harness()
  await h.connect()
  h.images["/clip/photo.jpg"] = "SlBH"
  await h.deliver([h.submit("r1", "read /clip/gone.png", { images: ["/clip/gone.png", "/clip/photo.jpg"] })])
  assert.equal(h.sends.length, 1)
  assert.equal(typeof h.sends[0].content, "string")
  assert.ok(h.sends[0].text.startsWith("read /clip/gone.png"))
})

test("dictation while omp works is steered and confirmed as soon as omp queues it", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  await h.deliver([h.submit()])
  assert.deepEqual(h.sends[0].options, { deliverAs: "steer" })
  const submitted = h.replies().find((b) => b.op === "submitted")
  assert.equal(submitted?.request, "r1")
  assert.equal(submitted?.turn, "")
})

test("a steer is reported taken into the turn when omp delivers it at the next boundary, however long that takes", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  await h.deliver([h.submit()])
  await h.advance(83_000)
  h.emit("message_start", h.user(h.sends[0].text))
  await h.settle()
  const absorbed = h.events().find((b) => b.op === "absorbed")
  assert.equal(absorbed?.turn, h.turn(1))
  assert.equal(h.replies().filter((b) => b.op === "submitted").length, 1)
})

const costCap = "Cost cap reached: this session spent $0.0005 of its $0.0000 cap (--max-cost / session.maxCost), so the next model request was not sent."

const refusedByOmp = (h: ReturnType<typeof harness>) => {
  h.live.editor = h.sends[0].text
  h.sends[0].drop(Object.assign(new Error(costCap), { name: "PromptDroppedError" }))
}

test("a message omp does not admit is refused with omp's words, the user's own draft replaces the message omp put back, and the next send still goes through", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "and also"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.equal(h.live.editor, "")
  refusedByOmp(h)
  await h.settle()
  assert.deepEqual(h.replies().filter((b) => b.request === "r1").map((b) => [b.op, b.reason]), [["ack", undefined], ["refused", costCap]])
  assert.equal(h.live.editor, "and also")
  h.live.editor = ""
  await h.deliver([h.submit("r2", "and this")])
  await h.taken()
  assert.equal(h.replies().find((b) => b.op === "submitted")?.request, "r2")
})

test("a refused message with no draft leaves the editor empty, never holding the dictated words", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "run the tests")])
  refusedByOmp(h)
  await h.settle()
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, costCap)
  assert.equal(h.live.editor, "")
})

test("a refused message leaves alone whatever the user typed after omp put it back", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "and also"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  h.live.editor = "typed meanwhile"
  h.sends[0].drop(Object.assign(new Error(costCap), { name: "PromptDroppedError" }))
  await h.settle()
  assert.equal(h.live.editor, "typed meanwhile")
})

test("a finished run is the run's own end, never a loop that omp will continue", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("message_end", h.assistant("first try failed", "error"))
  await h.pauses(false)
  assert.equal(h.ops().includes("turnComplete"), false)
  h.emit("agent_start")
  h.emit("message_end", h.assistant("done"))
  await h.runEnds()
  const complete = h.events().filter((b) => b.op === "turnComplete")
  assert.equal(complete.length, 1)
  assert.equal(complete[0].reason, "complete")
  assert.equal(complete[0].answer, "done")
})

test("a stop-hook continuation and goal or reminder turns stay inside one turn", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("message_end", h.assistant("HELLO"))
  await h.pauses(false)
  h.emit("before_agent_start", { reason: "prompt" })
  h.emit("agent_start")
  h.emit("message_start", { message: { role: "custom", customType: "session-stop-continuation", content: "Now also say CONTINUED." } })
  h.emit("message_end", h.assistant("HELLO CONTINUED"))
  await h.runEnds()
  const started = h.events().filter((b) => b.op === "turnStarted")
  const complete = h.events().filter((b) => b.op === "turnComplete")
  assert.equal(started.length, 1)
  assert.deepEqual(complete.map((b) => b.answer), ["HELLO CONTINUED"])
})

test("background work keeping the run open is not finished even though omp reports itself idle", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("message_end", h.assistant("OK"))
  await h.pauses(true)
  await h.advance(30_000)
  assert.equal(h.ops().includes("turnComplete"), false)
  await h.typed()
  assert.equal(h.ops().includes("turnComplete"), false)
  h.emit("agent_start")
  h.emit("message_end", h.assistant("The job finished."))
  await h.runEnds()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => b.answer), ["The job finished."])
})

test("a paused run wakes nothing while it waits, and its watchdog is back once the run goes on", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  await h.pauses(true)
  const before = h.timersMade
  await h.advance(20_000)
  assert.equal(h.timersMade, before)
  h.live.idle = false
  h.emit("agent_start")
  h.live.idle = true
  await h.advance(4_100)
  assert.equal(h.events().find((b) => b.op === "turnComplete")?.reason, "unknown")
})

test("dictation while background work keeps the run open is steered, never sent as a new message", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  await h.pauses(true)
  await h.deliver([h.submit()])
  assert.deepEqual(h.sends[0].options, { deliverAs: "steer" })
})

test("auto retry attempts stay one turn and a recovered answer is reported once", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  for (let attempt = 1; attempt <= 3; attempt++) {
    h.emit("message_end", h.assistant("", "error"))
    h.emit("auto_retry_start", { attempt })
    await h.pauses(false)
    h.emit("agent_start")
  }
  h.emit("message_end", h.assistant("recovered"))
  await h.runEnds()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => [b.reason, b.answer]), [["complete", "recovered"]])
})

test("a run that fails for good reports an error", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("message_end", h.assistant("", "error"))
  h.emit("auto_retry_end", { success: false, attempt: 10 })
  await h.runEnds()
  assert.equal(h.events().find((b) => b.op === "turnComplete")?.reason, "error")
})

test("a run the user stopped, with no stop hook, reports aborted", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("message_end", h.assistant("", "aborted"))
  h.live.idle = true
  h.emit("agent_end", { messages: [] })
  await h.settle()
  assert.equal(h.events().find((b) => b.op === "turnComplete")?.reason, "aborted")
})

test("a run whose end was missed is still closed once omp has been idle across two checks", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.live.idle = true
  await h.advance(4_100)
  assert.equal(h.events().find((b) => b.op === "turnComplete")?.reason, "unknown")
})

test("dictation during a tool approval goes as an aside, which leaves the approval open, and is confirmed when omp takes it", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "bash", args: { command: "echo APPROVED" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "bash", approvalMode: "always-ask" })
  await h.settle()
  await h.deliver([h.submit()])
  assert.deepEqual(h.sends[0].options, { deliverAs: "aside" })
  h.sends[0].settle()
  await h.advance(5_000)
  assert.equal(h.replies().find((b) => b.op === "submitted")?.request, "r1")
  assert.equal(h.replies().find((b) => b.op === "refused"), undefined)
  h.emit("tool_approval_resolved", { toolCallId: "t1", toolName: "bash", approved: true })
  await h.settle()
  assert.deepEqual(h.events().filter((b) => b.op === "waiting").map((b) => "waiting" in b), [true, false])
  h.emit("message_start", h.user(h.sends[0].text))
  await h.settle()
  assert.equal(h.events().find((b) => b.op === "absorbed")?.turn, h.turn(1))
  await h.deliver([h.submit("r2")])
  assert.deepEqual(h.sends[1].options, { deliverAs: "steer" })
})

test("an approval omp gives a reason for reports waiting with that reason as its title, on the tool being approved", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "bash", args: { command: "rm -rf build" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "bash", reason: "Critical pattern detected", approvalMode: "always-ask" })
  await h.settle()
  assert.deepEqual(h.events().find((b) => b.op === "waiting")?.waiting, {
    kind: "confirm", title: "Critical pattern detected", tool: "bash", detail: '{"command":"rm -rf build"}',
  })
})

test("an approval with no reason reports waiting with no title", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "write", args: { path: "README.md", content: "hello" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "write", approvalMode: "always-ask" })
  await h.settle()
  assert.deepEqual(h.events().find((b) => b.op === "waiting")?.waiting, {
    kind: "confirm", tool: "write", detail: '{"path":"README.md","content":"hello"}',
  })
})

test("an approval names the tool being approved even when a tool running beside it started later", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "write", args: { path: "a.txt" } })
  h.emit("tool_execution_start", { toolCallId: "t2", toolName: "read", args: { path: "b.txt" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "write", approvalMode: "always-ask" })
  await h.settle()
  const waiting = h.events().find((b) => b.op === "waiting")?.waiting
  assert.equal(waiting?.tool, "write")
  assert.equal(waiting?.detail, '{"path":"a.txt"}')
})

test("an approval whose tool was never seen starting still names the tool from the approval", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "t0", toolName: "read", args: { path: "b.txt" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "bash", approvalMode: "always-ask" })
  await h.settle()
  assert.deepEqual(h.events().find((b) => b.op === "waiting")?.waiting, { kind: "confirm", tool: "bash" })
})

test("a long approval reason is cut to the title limit", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "t1", toolName: "write", args: { path: "x" } })
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "write", reason: `Restricted folder: /${"d/".repeat(400)}` })
  await h.settle()
  assert.equal(h.events().find((b) => b.op === "waiting")?.waiting.title, `Restricted folder: /${"d/".repeat(400)}`.slice(0, 300))
})

test("dictation while the model's ask tool is open goes as an aside, which leaves the question open", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_execution_start", { toolCallId: "a1", toolName: "ask", args: { form: "Color preference" } })
  await h.settle()
  assert.equal(h.events().find((b) => b.op === "waiting")?.waiting.kind, "select")
  await h.deliver([h.submit()])
  assert.deepEqual(h.sends[0].options, { deliverAs: "aside" })
  assert.equal(h.replies().find((b) => b.op === "refused"), undefined)
  h.emit("tool_execution_end", { toolCallId: "a1", toolName: "ask", isError: false })
  await h.settle()
  assert.deepEqual(h.events().filter((b) => b.op === "waiting").map((b) => "waiting" in b), [true, false])
  await h.deliver([h.submit("r2")])
  assert.deepEqual(h.sends[1].options, { deliverAs: "steer" })
})

test("an open plan review still holds dictation while an approval is open beside it", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "bash" })
  h.emit("plan_review_requested", { reviewId: "p1", sessionId: "s1", title: "Refactor the parser", planFilePath: "/p.md", planContent: "", options: [] })
  await h.settle()
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 0)
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "dialog")
})

test("a plan review holds dictation and is described by its title", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("plan_review_requested", { reviewId: "p1", sessionId: "s1", title: "Refactor the parser", planFilePath: "/p.md", planContent: "", options: [] })
  await h.settle()
  assert.equal(h.events().find((b) => b.op === "waiting")?.waiting.title, "Refactor the parser")
  await h.deliver([h.submit()])
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "dialog")
  h.emit("plan_review_resolved", { reviewId: "p1" })
  await h.settle()
  await h.deliver([h.submit("r2")])
  assert.equal(h.sends.length, 1)
})

test("a wait whose closing event never came ends with the run, so dictation is never held forever", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("plan_review_requested", { reviewId: "p1", title: "One" })
  h.emit("message_end", h.assistant("", "aborted"))
  await h.runEnds()
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 1)
})

test("a repeated or unmatched closing event never opens dictation early", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("plan_review_requested", { reviewId: "p1", title: "One" })
  h.emit("plan_review_requested", { reviewId: "p1", title: "One" })
  h.emit("plan_review_requested", { reviewId: "p2", title: "Two" })
  h.emit("plan_review_resolved", { reviewId: "p9" })
  h.emit("plan_review_resolved", { reviewId: "p1" })
  h.emit("plan_review_resolved", { reviewId: "p1" })
  await h.settle()
  await h.deliver([h.submit()])
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "dialog")
})

test("another extension's dialog has no signal in omp, so only the keyboard holds dictation", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 0)
  await h.advance(3_000)
  assert.equal(h.sends.length, 1)
})

test("a typed prompt is reported and refuses dictation decided before it", async () => {
  const h = harness()
  await h.connect()
  await h.typed()
  assert.equal(h.events().find((b) => b.op === "typed")?.prompts, 1)
  await h.deliver([h.submit("r1", "run the tests", { expectedPrompts: 0 })])
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "typedSince")
})

test("a leading slash or bang is sent as plain text", async () => {
  const h = harness()
  await h.connect()
  await h.deliver([h.submit("r1", "/new")])
  assert.ok(h.sends[0].text.startsWith("/new"))
})

test("dictation never sends over a draft it cannot join, and leaves the draft in place", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "half typed"
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 0)
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "draft")
  assert.equal(h.live.editor, "half typed")
})

test("dictation for the conversation in front joins the user's draft and sends it as one message", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "and also"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.ok(h.sends[0].text.startsWith("and also run the tests"))
  assert.equal(h.live.editor, "")
})

test("a draft is not joined while omp compacts, and is again once compaction ends", async () => {
  for (const [begins, ends] of [["session_before_compact", "session_compact"], ["auto_compaction_start", "auto_compaction_end"]]) {
    const h = harness()
    await h.connect()
    h.live.editor = "and also"
    h.emit(begins)
    await h.deliver([h.submit("r1", "run the tests", { merge: true })])
    assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "draft", begins)
    h.emit(ends)
    await h.deliver([h.submit("r2", "run the tests", { merge: true })])
    assert.equal(h.sends.length, 1, ends)
  }
})

test("a compaction that failed without an event never keeps blocking joins past the run", async () => {
  const h = harness()
  await h.connect()
  h.emit("session_before_compact")
  await h.runStarts()
  await h.runEnds()
  h.live.editor = "and also"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.equal(h.sends.length, 1)
})

test("a /clear while background work keeps the run open closes that turn, so the next dictation starts a run", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  await h.pauses(true)
  h.emit("session_clear")
  await h.settle()
  assert.deepEqual(h.events().filter((b) => b.op === "turnComplete").map((b) => b.reason), ["unknown"])
  await h.deliver([h.submit()])
  assert.deepEqual(h.sends[0].options, {})
})

test("a run already going when the connector loaded still reports its end", async () => {
  const h = harness()
  h.live.idle = false
  await h.connect()
  await h.runEnds()
  assert.equal(h.events().filter((b) => b.op === "turnComplete").length, 1)
})

test("a /clear refuses a dictation still waiting for the keyboard, so it never lands in the cleared conversation", async () => {
  const h = harness()
  await h.connect()
  await h.key()
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 0)
  h.emit("session_clear")
  await h.advance(6_000)
  assert.equal(h.sends.length, 0)
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "sessionChanged")
})

test("a /clear drops a joined dictation's pending draft restore, so the old draft never reappears", async () => {
  const h = harness()
  await h.connect()
  h.live.editor = "and also"
  await h.deliver([h.submit("r1", "run the tests", { merge: true })])
  assert.equal(h.sends.length, 1)
  assert.equal(h.live.editor, "")
  h.emit("session_clear")
  await h.advance(5_000)
  assert.equal(h.live.editor, "")
})

test("a /clear closes an open wait, so dictation is not held by a dialog that is gone", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("tool_approval_requested", { toolCallId: "t1", toolName: "bash" })
  h.live.idle = true
  h.emit("session_clear")
  await h.deliver([h.submit()])
  assert.equal(h.sends.length, 1)
})

test("a run's end that arrives after a /clear closed it reports no second completion", async () => {
  const h = harness()
  await h.connect()
  await h.runStarts()
  h.emit("session_clear")
  await h.runEnds()
  assert.equal(h.events().filter((b) => b.op === "turnComplete").length, 1)
})

test("a new, resumed or forked conversation in the same omp says hello for its own id and drops the old one's work", async () => {
  for (const reason of ["new", "resume", "fork"]) {
    const h = harness()
    await h.connect()
    await h.runStarts()
    h.live.session = `s-${reason}`
    h.live.idle = true
    h.emit("session_switch", { reason, previousSessionFile: "/x.jsonl" })
    await h.settle()
    const hello = h.events().filter((b) => b.op === "hello").at(-1)
    assert.equal(hello?.session, `s-${reason}`, reason)
    assert.equal(hello?.gap, reason === "resume", reason)
    assert.equal(hello?.idle, true, reason)
    assert.equal(h.events().some((b) => b.op === "turnComplete"), false, reason)
  }
})

test("a branch into a new session file is a new conversation; one that keeps the id is not", async () => {
  const h = harness()
  await h.connect()
  h.emit("session_branch", { reason: "branch", previousSessionFile: "/x.jsonl" })
  await h.settle()
  assert.equal(h.events().filter((b) => b.op === "hello").length, 1)
  h.live.session = "s2"
  h.emit("session_branch", { reason: "branch", previousSessionFile: "/x.jsonl" })
  await h.settle()
  assert.equal(h.events().filter((b) => b.op === "hello").at(-1)?.session, "s2")
})

test("a command for the conversation omp replaced is refused without acting", async () => {
  const h = harness()
  await h.connect()
  const old = h.submit()
  h.live.session = "s2"
  await h.deliver([old])
  assert.equal(h.sends.length, 0)
  assert.equal(h.replies().find((b) => b.op === "refused")?.reason, "sessionChanged")
})

test("quitting omp ends the connector's requests", async () => {
  const h = harness()
  await h.connect()
  h.emit("session_shutdown")
  await h.settle()
  const before = h.requests.length
  await h.advance(60_000)
  assert.equal(h.requests.length, before)
})

test("the read-aloud tool and command are offered in omp as in Pi", async () => {
  const h = harness()
  await h.connect()
  assert.equal(h.tools[0]?.name, "keyscribe_dev_tell_me_when_done")
  assert.ok(h.commands.has("keyscribe-dev"))
})

test("no handler waits on the bridge or returns work for omp to await", async () => {
  const h = harness()
  await h.connect()
  h.autoEvents = false
  const results = [
    ...h.emit("input", { text: "x", source: "interactive" }),
    ...h.emit("agent_start"),
    ...h.emit("tool_execution_start", { toolCallId: "t", toolName: "ask", args: {} }),
    ...h.emit("tool_execution_end", { toolCallId: "t", toolName: "ask" }),
    ...h.emit("tool_approval_requested", { toolCallId: "u", toolName: "bash" }),
    ...h.emit("tool_approval_resolved", { toolCallId: "u", toolName: "bash" }),
    ...h.emit("message_end", h.assistant("x")),
    ...h.emit("agent_end", { messages: [], willContinue: true }),
    ...h.emit("agent_end", { messages: [] }),
  ]
  assert.deepEqual(results.filter((r) => r !== undefined), [])
  await h.settle()
  assert.deepEqual(h.ops().slice(1), ["typed"])
  assert.equal(h.open("/event").length, 1)
})
