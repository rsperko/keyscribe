import assert from "node:assert/strict"
import { test } from "node:test"
import { traceLimit } from "../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts"
import { newPageReported, pageChange } from "./lib/ultimate.ts"

const line = (entry: object) => JSON.stringify({ at: 1, ...entry })
const hub = line({ dir: "ext->hub", path: "/event" })
const page = (id: string) => line({ dir: "page->ext", page: id, focused: false })

test("a new page's report is found among every kind of trace record, and a known page's is not", () => {
  const trace = [hub, page("p1"), hub, page("p2"), ""].join("\n")
  assert.equal(newPageReported(trace, new Set(["p1"])), true)
  assert.equal(newPageReported(trace, new Set(["p1", "p2"])), false)
})

test("a trace full of other records fails naming its limit, unless the new page's report made it in", () => {
  const full = [page("p1"), ...Array(traceLimit - 1).fill(hub)].join("\n") + "\n"
  assert.equal(newPageReported(full, new Set()), true)
  assert.throws(() => newPageReported(full, new Set(["p1"])), new RegExp(`limit of ${traceLimit} records`))
  assert.equal(newPageReported(Array(traceLimit - 1).fill(hub).join("\n"), new Set()), false)
})

test("a page change carries ordered ops for current Ultimate and the same values as set for older ones", () => {
  assert.deepEqual(pageChange({ "shell.surface": "agent", "shell.conversation": 7, "ext.side-chat.front": null }), {
    ops: [{ key: "shell.surface", value: "agent" }, { key: "shell.conversation", value: 7 }, { key: "ext.side-chat.front", value: null }],
    set: { "shell.surface": "agent", "shell.conversation": 7, "ext.side-chat.front": null },
  })
})
