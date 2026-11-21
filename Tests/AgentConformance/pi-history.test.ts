import assert from "node:assert/strict"
import { test } from "node:test"
import { piMessages } from "./lib/pi.ts"

test("Pi records string and block content without mixing tool or thinking text into replies", () => {
  assert.deepEqual(piMessages([
    { type: "session", id: "session" },
    { type: "message", id: "u1", message: { role: "user", content: "Say ready" } },
    { type: "message", id: "t1", message: { role: "toolResult", content: "internal" } },
    { type: "message", id: "a1", message: { role: "assistant", content: [
      { type: "thinking", thinking: "internal" }, { type: "text", text: "ready" },
    ] } },
    { type: "message", id: "u2", message: { role: "user", content: [{ type: "text", text: "Again" }] } },
    { type: "message", id: "a2", message: { role: "assistant", content: "ready again" } },
  ]), [
    { role: "user", text: "Say ready", turn: "u1" },
    { role: "agent", text: "ready", turn: "u1" },
    { role: "user", text: "Again", turn: "u2" },
    { role: "agent", text: "ready again", turn: "u2" },
  ])
})
