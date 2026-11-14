import assert from "node:assert/strict"
import { test } from "node:test"
import plugin, { configPaths } from "../../Sources/KeyScribe/Resources/BBPlugin/server.ts"

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
  }
  await plugin(bb)
  assert.equal(disposers.length, 1)
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r))
  assert.equal(statuses.length, 1)
  disposers[0]()
})
