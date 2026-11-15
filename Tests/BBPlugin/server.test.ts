import assert from "node:assert/strict"
import { test } from "node:test"
import plugin, { configPaths, rpcContract } from "../../Sources/KeyScribe/Resources/BBPlugin/server.ts"

test("the settings are looked for beside the entry bb loads, then one folder up", () => {
  assert.deepEqual(configPaths("file:///plugins/ks/server.ts"), ["/plugins/ks/keyscribe.json", "/plugins/keyscribe.json"])
  assert.deepEqual(configPaths("file:///plugins/ks/dist/server.js"), ["/plugins/ks/dist/keyscribe.json", "/plugins/ks/keyscribe.json"])
})

test("the entry hands bb its cleanup, and without settings asks bb to show it needs setting up", async () => {
  const disposers: Array<() => unknown> = []
  const statuses: string[] = []
  const bb: any = {
    sdk: { threads: { list: async () => [], promptHistory: async () => [] } },
    events: { on: () => {} },
    log: { info: () => {} },
    status: { needsConfiguration: (message: string) => statuses.push(message) },
    onDispose: (hook: () => unknown) => disposers.push(hook),
    rpc: { register: () => {} },
  }
  await plugin(bb)
  assert.equal(disposers.length, 1)
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r))
  assert.equal(statuses.length, 1)
  disposers[0]()
})

test("bb's windows report to the server through one method whose input is checked before it is used", async () => {
  const registered: Array<{ contract: any; handlers: any }> = []
  const bb: any = {
    sdk: { threads: { list: async () => [], promptHistory: async () => [] } },
    events: { on: () => {} },
    log: { info: () => {} },
    status: { needsConfiguration: () => {} },
    onDispose: () => {},
    rpc: { register: (contract: any, handlers: any) => registered.push({ contract, handlers }) },
  }
  await plugin(bb)
  assert.equal(registered.length, 1)
  assert.deepEqual(Object.keys(registered[0].contract), ["window"])
  assert.equal(registered[0].handlers.window({ window: "w1", focused: true, thread: "thr_a" }), null)
  const check = (value: unknown) => rpcContract.window.input["~standard"].validate(value)
  assert.deepEqual(check({ window: "w1", focused: true, thread: null }), { value: { window: "w1", focused: true, thread: null } })
  for (const bad of [null, {}, { window: 1, focused: true, thread: null }, { window: "w", focused: "yes", thread: null },
    { window: "w", focused: true, thread: 3 }, { window: "w".repeat(65), focused: true, thread: null }]) {
    assert.ok("issues" in (check(bad) as object))
  }
  assert.deepEqual(rpcContract.window.output["~standard"].validate(null), { value: null })
})
