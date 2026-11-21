import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { test } from "node:test"
import { mkdtempSync, mkdirSync, realpathSync, rmSync, symlinkSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"

const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("@earendil-works/")) return { url: "ultimate-stub:" + specifier, shortCircuit: true }
    return next(specifier, context)
  },
  load(url, context, next) {
    if (url.startsWith("ultimate-stub:")) return {
      format: "module", shortCircuit: true,
      source: "export const BACKGROUND_CONTEXT = {}; export const defineExtension = x => x; export const defineTool = x => x; export const obj = x => x;",
    }
    return next(url, context)
  },
})
const server = await import("../../Sources/KeyScribe/Resources/UltimateConnector/server.ts")
hooks.deregister()

test("a connector that is not ready reports uncertainty instead of an empty roster", async () => {
  await assert.rejects(server.actions.list(), /not ready/)
})

test("one rule lists every writable sidebar conversation with what the app needs, and says why the rest are not listed", () => {
  const kinds: Array<[string, any, any]> = [
    ["root", { id: 1, cwd: "/w" }, "Ultimate shows its root context, which has no writable composer."],
    ["lander", { id: 2, label: "lander", title: "@lander", cwd: "/w" }, "Ultimate shows its lander, which has no writable composer."],
    ["standing agent", { id: 3, label: "agent", title: "@ultimate", cwd: "/w", inputAt: 5000, answerAt: 9000 },
      { id: 3, handle: "@ultimate", title: "@ultimate", cwd: "/w", activeAt: 9 }],
    ["branch", { id: 4, label: "coordinator", title: "Discussing plum orchards", cwd: "/w/wt/4", inputAt: 7000 },
      { id: 4, title: "Discussing plum orchards", cwd: "/w/wt/4", activeAt: 7 }],
    ["ordinary conversation", { id: 5, title: "My conversation", cwd: "/w" }, { id: 5, title: "My conversation", cwd: "/w" }],
    ["side chat", { id: 6, label: "side-chat", title: "Side chat", cwd: "/w" }, { id: 6, title: "Side chat", cwd: "/w" }],
    ["owned subagent", { id: 7, label: "feather", parentConversationId: 4, ownerTaskId: 8, cwd: "/w/wt/4" },
      { id: 7, handle: "feather", cwd: "/w/wt/4" }],
    ["untitled conversation", { id: 8, cwd: "/w" }, { id: 8, cwd: "/w" }],
  ]
  for (const [kind, conversation, expected] of kinds) {
    if (typeof expected === "string") {
      assert.equal(server.unlistedReason(conversation), expected, kind)
      assert.equal(server.listing({ conversations: () => [conversation] } as any).length, 0, kind)
    } else {
      assert.equal(server.unlistedReason(conversation), undefined, kind)
      assert.deepEqual(server.listing({ conversations: () => [conversation] } as any), [expected], kind)
    }
  }
})

test("a newly shown conversation is verified directly before the cached list catches up", async () => {
  const host = {
    home: "/u/project", metadata: {},
    harness: () => ({
      conversation: async (id: number) => id === 70 ? { agent: async () => ({ cwd: "/w/new" }) } : undefined,
      snapshot: async () => ({ label: "coordinator", title: "Discussing plum orchards" }),
    }),
  }
  assert.deepEqual(await server.pageConversation(host as any, 70), { id: 70, label: "coordinator", title: "Discussing plum orchards", cwd: "/w/new" })
  assert.equal(await server.pageConversation(host as any, 999), undefined)
  const lander = { ...host, harness: () => ({ ...host.harness(), snapshot: async () => ({ label: "lander" }) }) }
  assert.equal(await server.pageConversation(lander as any, 70), undefined)
  assert.equal(await server.pageConversation(host as any, 1), undefined)
})

test("only a focused page showing a conversation Ultimate has not listed yet is looked up", () => {
  const host = { conversations: () => [{ id: 2, label: "lander", cwd: "/w" }, { id: 4, label: "coordinator", cwd: "/w/wt/4" }] }
  const report = (conversation: number | null, more: object = {}) => ({ page: "p", focused: true, conversation, draft: false, ...more })
  const fresh = [{ id: 71, cwd: "/w/new" }]
  assert.equal(server.verifiesShown(host as any, report(70), fresh as any), true)
  assert.equal(server.verifiesShown(host as any, report(2), fresh as any), false, "lander")
  assert.equal(server.verifiesShown(host as any, report(4), fresh as any), false, "listed")
  assert.equal(server.verifiesShown(host as any, report(71), fresh as any), false, "already verified")
  assert.equal(server.verifiesShown(host as any, report(70, { focused: false }), fresh as any), false, "unfocused")
  assert.equal(server.verifiesShown(host as any, report(70, { problem: "A dialog covers Ultimate\u2019s composer." }), fresh as any), false, "problem")
  assert.equal(server.verifiesShown(host as any, report(null), fresh as any), false, "nothing shown")
})

test("the installed server accepts homes reached through symlinked setups and rejects neighboring setups", () => {
  const root = mkdtempSync(join(tmpdir(), "ks-ultimate-path-"))
  try {
    const setup = join(root, "actual", ".ultimate")
    const home = join(setup, "projects", "kestrel")
    mkdirSync(home, { recursive: true })
    const linked = join(root, "linked")
    symlinkSync(join(root, "actual"), linked)
    assert.equal(typeof server.served, "function", "exercise the server's installation boundary")
    for (const folder of [setup, join(linked, ".ultimate")])
      for (const state of [home, join(linked, ".ultimate", "projects", "kestrel"), realpathSync(home)])
        assert.equal(server.served({ home: state }, { setup: folder }), true)
    mkdirSync(join(root, "actual", ".ultimate-other", "projects", "kestrel"), { recursive: true })
    assert.equal(server.served({ home: join(root, "actual", ".ultimate-other", "projects", "kestrel") }, { setup }), false)
    assert.equal(server.served({ home }, { setup: join(root, "missing") }), false)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
