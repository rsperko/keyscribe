import assert from "node:assert/strict"
import { test } from "node:test"
import { ultimateMessages } from "./lib/ultimate.ts"

test("a branch's take and reply are found across every history page", async () => {
  const cursors: number[] = []
  const pages = new Map([
    [Number.MAX_SAFE_INTEGER, { entries: [{ id: 12, kind: "pi.assistant", model: [{ type: "text", text: "ready" }] }], before: 12 }],
    [12, { entries: [{ id: 11, kind: "pi.user", input: true, model: [{ type: "text", text: "Reply ready" }] }], before: 11 }],
    [11, { entries: [{ id: 10, kind: "pi.assistant", model: [{ type: "text", text: "earlier" }] }] }],
  ])
  const messages = await ultimateMessages(async before => {
    cursors.push(before)
    return pages.get(before)!
  })
  assert.deepEqual(cursors, [Number.MAX_SAFE_INTEGER, 12, 11])
  assert.deepEqual(messages, [
    { role: "agent", text: "earlier", turn: undefined },
    { role: "user", text: "Reply ready", turn: "11" },
    { role: "agent", text: "ready", turn: "11" },
  ])
})

test("an invalid history cursor fails instead of looping forever", async () => {
  await assert.rejects(ultimateMessages(async before => ({ entries: [], before })), /cursor/)
})

test("the recorded reply contains visible message text without thinking or provider metadata", async () => {
  const messages = await ultimateMessages(async () => ({ entries: [
    { id: 1, kind: "pi.user", input: true, model: [{ role: "user", content: "Say ready", timestamp: 123 }] },
    { id: 2, kind: "pi.assistant", model: [{ role: "assistant", content: [
      { type: "thinking", thinking: "internal", thinkingSignature: "signature" },
      { type: "text", text: "ready", textSignature: "signature" },
    ], provider: "provider", model: "model", stopReason: "stop" }] },
  ] }))
  assert.deepEqual(messages, [
    { role: "user", text: "Say ready", turn: "1" },
    { role: "agent", text: "ready", turn: "1" },
  ])
})
