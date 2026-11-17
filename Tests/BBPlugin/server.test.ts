import assert from "node:assert/strict"
import { test } from "node:test"
import plugin, { composeRelay, configPaths, interactionStatus, readAloudToolName, rpcContract } from "../../Sources/KeyScribe/Resources/BBPlugin/server.ts"

function fakeBb(overrides: Record<string, unknown> = {}): any {
  return {
    pluginId: "keyscribe-dev",
    sdk: { threads: { list: async () => [], promptHistory: async () => [], interactions: { get: async () => ({ status: "pending" }) } } },
    events: { on: () => {} },
    log: { info: () => {} },
    status: { needsConfiguration: () => {} },
    onDispose: () => {},
    rpc: { register: () => {} },
    agents: { registerTool: () => {}, configure: () => {} },
    ...overrides,
  }
}

test("the settings are looked for beside the entry bb loads, then one folder up", () => {
  assert.deepEqual(configPaths("file:///plugins/ks/server.ts"), ["/plugins/ks/keyscribe.json", "/plugins/keyscribe.json"])
  assert.deepEqual(configPaths("file:///plugins/ks/dist/server.js"), ["/plugins/ks/dist/keyscribe.json", "/plugins/ks/keyscribe.json"])
})

test("the entry hands bb its cleanup, and without settings asks bb to show it needs setting up", async () => {
  const disposers: Array<() => unknown> = []
  const statuses: string[] = []
  const bb = fakeBb({
    status: { needsConfiguration: (message: string) => statuses.push(message) },
    onDispose: (hook: () => unknown) => disposers.push(hook),
  })
  await plugin(bb)
  assert.equal(disposers.length, 1)
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r))
  assert.equal(statuses.length, 1)
  disposers[0]()
})

test("bb's windows report to the server through one method whose input is checked before it is used", async () => {
  const registered: Array<{ contract: any; handlers: any }> = []
  const bb = fakeBb({ rpc: { register: (contract: any, handlers: any) => registered.push({ contract, handlers }) } })
  await plugin(bb)
  assert.equal(registered.length, 1)
  assert.deepEqual(Object.keys(registered[0].contract), ["window", "labels", "readAloud", "composing", "composed"])
  assert.equal(registered[0].handlers.window({ window: "w1", focused: true, thread: "thr_a" }), null)
  const check = (value: unknown) => rpcContract.window.input["~standard"].validate(value)
  assert.deepEqual(check({ window: "w1", focused: true, thread: null }), { value: { window: "w1", focused: true, thread: null } })
  for (const bad of [null, {}, { window: 1, focused: true, thread: null }, { window: "w", focused: "yes", thread: null },
    { window: "w", focused: true, thread: 3 }, { window: "w".repeat(65), focused: true, thread: null }]) {
    assert.ok("issues" in (check(bad) as object))
  }
  assert.deepEqual(rpcContract.window.output["~standard"].validate(null), { value: null })
})

test("bb's sidebar reads every row's name in one keyed read whose keys are checked before they are used", async () => {
  const registered: Array<{ handlers: any }> = []
  const bb = fakeBb({ rpc: { register: (_contract: any, handlers: any) => registered.push({ handlers }) } })
  await plugin(bb)
  assert.deepEqual(registered[0].handlers.labels({ keys: ["thr_a", "thr_b"] }), { thr_a: null, thr_b: null })
  const check = (value: unknown) => rpcContract.labels.input["~standard"].validate(value)
  assert.deepEqual(check({ keys: ["thr_a"] }), { value: { keys: ["thr_a"] } })
  for (const bad of [null, {}, { keys: "thr_a" }, { keys: [1] }, { keys: ["t".repeat(129)] }, { keys: Array(1001).fill("t") }]) {
    assert.ok("issues" in (check(bad) as object))
  }
  const answer = (value: unknown) => rpcContract.labels.output["~standard"].validate(value)
  assert.ok("value" in (answer({ thr_a: "“docs”", thr_b: null }) as object))
  assert.ok("issues" in (answer({ thr_a: 3 }) as object))
})

test("a new name from the app redraws bb's rows", async () => {
  let invalidated = 0
  const bb = fakeBb({ rpc: { register: () => {}, experimental_invalidateAll: () => { invalidated += 1 } } })
  const { labelsChanged } = await import("../../Sources/KeyScribe/Resources/BBPlugin/server.ts")
  labelsChanged(bb)
  assert.equal(invalidated, 1)
  labelsChanged(fakeBb())
})

test("every bb agent is offered a tool, named for this copy of the plugin, that asks the app to read the turn aloud", async () => {
  const tools: any[] = []
  const configured: Array<(context: any) => any> = []
  const bb = fakeBb({ agents: { registerTool: (tool: any) => tools.push(tool), configure: (provider: any) => configured.push(provider) } })
  await plugin(bb)
  assert.equal(readAloudToolName("keyscribe-dev"), "keyscribe_dev_tell_me_when_done")
  assert.equal(tools.length, 1)
  assert.equal(tools[0].name, "keyscribe_dev_tell_me_when_done")
  assert.match(tools[0].description, /Call this only when the user explicitly asks/)
  assert.deepEqual(tools[0].parameters, { type: "object", properties: {}, additionalProperties: false })
  assert.equal(configured.length, 1)
  assert.deepEqual(configured[0]({ thread: { id: "thr_a" } }), { tools: ["keyscribe_dev_tell_me_when_done"], skills: [] })
  const answer = await tools[0].execute({}, { threadId: "thr_a", projectId: "p", signal: new AbortController().signal })
  assert.match(answer, /didn’t confirm the request/)
})

test("whether bb still waits on a prompt is read from bb, and a failed read is left to the caller", async () => {
  const asked: any[] = []
  const sdk: any = { threads: { interactions: { get: async (args: any) => { asked.push(args); return { status: "resolved" } } } } }
  assert.equal(await interactionStatus(sdk, "thr_a", "i1"), "resolved")
  assert.deepEqual(asked, [{ threadId: "thr_a", interactionId: "i1" }])
  const failing: any = { threads: { interactions: { get: async () => { throw new Error("busy") } } } }
  await assert.rejects(interactionStatus(failing, "thr_a", "i1"))
  const odd: any = { threads: { interactions: { get: async () => ({}) } } }
  assert.equal(await interactionStatus(odd, "thr_a", "i1"), null)
})

test("a command in bb's message box asks for its thread's reply through one method whose input is checked, and hears back what to show", async () => {
  const registered: Array<{ handlers: any }> = []
  const bb = fakeBb({ rpc: { register: (_contract: any, handlers: any) => registered.push({ handlers }) } })
  await plugin(bb)
  assert.deepEqual(await registered[0].handlers.readAloud({ thread: "thr_unknown", on: true }),
    { message: "the voice app didn’t confirm the request, so a reply update isn’t certain." })
  const check = (value: unknown) => rpcContract.readAloud.input["~standard"].validate(value)
  assert.deepEqual(check({ thread: "thr_a", on: false }), { value: { thread: "thr_a", on: false } })
  for (const bad of [null, {}, { thread: 1, on: true }, { thread: "thr_a" }, { thread: "x".repeat(129), on: true }]) {
    assert.ok("issues" in (check(bad) as object))
  }
  const output = (value: unknown) => rpcContract.readAloud.output["~standard"].validate(value)
  assert.deepEqual(output({ message: "ok" }), { value: { message: "ok" } })
  assert.ok("issues" in (output({ message: null }) as object))
})

test("a join is asked of every window over one channel and settled only by the answer of the window that took it", async () => {
  const published: Array<{ channel: string; payload: any }> = []
  const timers: Array<{ ms: number; fire: () => void; live: boolean }> = []
  const relay = composeRelay((channel, payload) => published.push({ channel, payload }), (ms, fire) => {
    const timer = { ms, fire, live: true }
    timers.push(timer)
    return () => { timer.live = false }
  })
  const joined = relay.compose("w1", "thr_a", "run the tests")
  assert.deepEqual(published.map((p) => [p.channel, p.payload.window, p.payload.thread, p.payload.text]), [["compose", "w1", "thr_a", "run the tests"]])
  const id = published[0].payload.id
  relay.answered({ id, outcome: "sent", joined: "too early" })
  assert.equal(relay.starting(id), true)
  assert.equal(relay.starting(id), false)
  relay.answered({ id: "someone else", outcome: "empty" })
  relay.answered({ id, outcome: "sent", joined: "half run the tests" })
  assert.deepEqual(await joined, { outcome: "sent", joined: "half run the tests" })
  assert.ok(timers.every((t) => !t.live))
})

test("a join no window takes up in time touched nothing, so it reads as an empty box, and a window that answers late is told not to start", async () => {
  const published: any[] = []
  const timers: Array<() => void> = []
  const relay = composeRelay((_channel, payload) => published.push(payload), (_ms, fire) => { timers.push(fire); return () => {} })
  const joined = relay.compose("w1", "thr_a", "run the tests")
  timers[0]()
  assert.deepEqual(await joined, { outcome: "empty" })
  assert.equal(relay.starting(published[0].id), false)
})

test("a join a window took up but never finished is left unanswered", async () => {
  const published: any[] = []
  const timers: Array<() => void> = []
  const relay = composeRelay((_channel, payload) => published.push(payload), (_ms, fire) => { timers.push(fire); return () => {} })
  const joined = relay.compose("w1", "thr_a", "run the tests")
  assert.equal(relay.starting(published[0].id), true)
  timers[1]()
  assert.equal(await joined, null)
})

test("the windows answer a join through one method whose input is checked before it is used", async () => {
  const registered: Array<{ contract: any }> = []
  await plugin(fakeBb({ rpc: { register: (contract: any) => registered.push({ contract }) }, realtime: { publish: () => {} } }))
  assert.deepEqual(Object.keys(registered[0].contract), ["window", "labels", "readAloud", "composing", "composed"])
  const starting = (value: unknown) => rpcContract.composing.input["~standard"].validate(value)
  assert.ok("value" in (starting({ id: "j1" }) as object))
  assert.ok("issues" in (starting({ id: 7 }) as object))
  assert.ok("value" in (rpcContract.composing.output["~standard"].validate({ go: false }) as object))
  const check = (value: unknown) => rpcContract.composed.input["~standard"].validate(value)
  assert.ok("value" in (check({ id: "j1", outcome: "sent", joined: "a b" }) as object))
  assert.ok("value" in (check({ id: "j1", outcome: "blocked" }) as object))
  for (const bad of [null, {}, { id: "j1", outcome: "sent" }, { id: "j1", outcome: "maybe" }, { id: 1, outcome: "empty" }]) {
    assert.ok("issues" in (check(bad) as object))
  }
})
