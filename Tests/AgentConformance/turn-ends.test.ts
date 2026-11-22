import assert from "node:assert/strict"
import { test } from "node:test"
import { bbMessages } from "./lib/bb.ts"
import { claudeMessages } from "./lib/claude.ts"
import { codexMessages } from "./lib/codex.ts"
import { piMessages } from "./lib/pi.ts"
import { ultimateMessages } from "./lib/ultimate.ts"

test("Pi ends a turn at its first reply that does not stop for a tool, whatever that reply says", () => {
  const reply = (id: string, stopReason: string, text: string) =>
    ({ type: "message", id, message: { role: "assistant", stopReason, content: text ? [{ type: "text", text }] : [] } })
  assert.deepEqual(piMessages([
    { type: "message", id: "u1", message: { role: "user", content: "Run it" } },
    reply("a1", "toolUse", "Running it now."),
    { type: "message", id: "u2", message: { role: "user", content: "Then say cherry" } },
    reply("a2", "stop", "Done"),
    { type: "message", id: "u3", message: { role: "user", content: "Again" } },
    reply("a3", "error", ""),
  ]), [
    { role: "user", text: "Run it", turn: "u1" },
    { role: "agent", text: "Running it now.", turn: "u1" },
    { role: "user", text: "Then say cherry", turn: "u2" },
    { role: "agent", text: "Done", turn: "u2" },
    { role: "ended", text: "", turn: "u2" },
    { role: "user", text: "Again", turn: "u3" },
    { role: "ended", text: "", turn: "u3" },
  ])
})

test("Ultimate ends a turn where its agent's reply stops for anything but a tool", async () => {
  const reply = (id: number, stopReason: string, text: string) =>
    ({ id, kind: "pi.assistant", model: [{ role: "assistant", content: [{ type: "text", text }], stopReason }] })
  const messages = await ultimateMessages(async () => ({ entries: [
    { id: 1, kind: "pi.user", input: true, model: [{ role: "user", content: "Run it" }] },
    reply(2, "toolUse", "Running it now."),
    reply(3, "aborted", "Stopped"),
  ] }))
  assert.deepEqual(messages, [
    { role: "user", text: "Run it", turn: "1" },
    { role: "agent", text: "Running it now.", turn: "1" },
    { role: "agent", text: "Stopped", turn: "1" },
    { role: "ended", text: "", turn: "1" },
  ])
})

test("bb ends a turn where its log records the turn completed", () => {
  const events = [
    { seq: 1, type: "client/turn/requested", data: { requestId: "r1", input: [{ type: "text", text: "Run it" }] } },
    { seq: 2, type: "turn/input/accepted", scope: { turnId: "t1" }, data: { clientRequestId: "r1" } },
    { seq: 3, type: "item/completed", scope: { turnId: "t1" }, data: { item: { type: "agentMessage", text: "Done" } } },
    { seq: 4, type: "turn/completed", scope: { turnId: "t1" }, data: {} },
    { seq: 5, type: "client/turn/requested", data: { requestId: "r2", input: [{ type: "text", text: "later" }] } },
  ]
  assert.deepEqual(bbMessages(events), [
    { role: "user", text: "Run it", turn: "t1" },
    { role: "agent", text: "Done", turn: "t1" },
    { role: "ended", text: "", turn: "t1" },
    { role: "user", text: "later", turn: undefined },
  ])
})

test("Codex ends each turn it no longer reports in progress", () => {
  const turn = (id: string, status: string, said: string, answer: string) => ({ id, status, items: [
    { type: "userMessage", content: [{ type: "text", text: said }] },
    { type: "agentMessage", text: answer },
  ] })
  assert.deepEqual(codexMessages([turn("t2", "inProgress", "Again", "Working"), turn("t1", "failed", "Run it", "Done")]), [
    { role: "user", text: "Run it", turn: "t1", mark: undefined },
    { role: "agent", text: "Done", turn: "t1" },
    { role: "ended", text: "", turn: "t1" },
    { role: "user", text: "Again", turn: "t2", mark: undefined },
    { role: "agent", text: "Working", turn: "t2" },
  ])
})

test("Claude Code ends a turn where its transcript records the turn's duration", () => {
  const lines = [
    { type: "user", uuid: "u1", message: { content: "Run it" } },
    { type: "assistant", message: { content: [{ type: "text", text: "Running it now." }], stop_reason: "tool_use" } },
    { type: "assistant", message: { content: [{ type: "text", text: "Done" }], stop_reason: "end_turn" } },
    { type: "system", subtype: "turn_duration", durationMs: 10 },
  ].map((entry) => JSON.stringify(entry)).join("\n")
  assert.deepEqual(claudeMessages(lines), [
    { role: "user", text: "Run it", turn: "u1" },
    { role: "agent", text: "Running it now.", turn: "u1" },
    { role: "agent", text: "Done", turn: "u1" },
    { role: "ended", text: "", turn: "u1" },
  ])
})
