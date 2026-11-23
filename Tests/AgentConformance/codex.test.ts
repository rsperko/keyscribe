import assert from "node:assert/strict"
import { test } from "node:test"
import { unlessUnwritten } from "./lib/codex.ts"

test("a Codex read made before the thread's first turn is written counts as not ready, and any other failure still fails", async () => {
  assert.equal(await unlessUnwritten(async () => { throw new Error(`thread/read: {"code":-32600,"message":"rollout at /x/rollout.jsonl is empty"}`) }), undefined)
  assert.equal(await unlessUnwritten(async () => "read"), "read")
  await assert.rejects(unlessUnwritten(async () => { throw new Error("thread/read: no thread") }), /no thread/)
})
