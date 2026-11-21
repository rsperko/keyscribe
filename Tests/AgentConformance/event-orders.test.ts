import assert from "node:assert/strict"
import { test } from "node:test"
import { eventOrders } from "./lib/event-orders.ts"

test("independent streams are interleaved exhaustively while each stream keeps its own order", () => {
  assert.deepEqual(eventOrders([["focus", "blur"], ["connect"]]), [
    ["focus", "blur", "connect"], ["focus", "connect", "blur"], ["connect", "focus", "blur"],
  ])
  assert.equal(eventOrders([["a"], ["b"], ["c"]]).length, 6)
})

test("an oversized ordering grid fails instead of silently testing only part of it", () => {
  assert.throws(() => eventOrders([["a"], ["b"], ["c"]], 5), /ordering limit/)
})
