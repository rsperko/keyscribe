import assert from "node:assert/strict"
import { test } from "node:test"
import { bbMessages } from "./lib/bb.ts"

const asked = (seq: number, requestId: string, text: string, initiator = "user") =>
  ({ seq, type: "client/turn/requested", scope: { kind: "thread" }, data: { requestId, initiator, input: [{ type: "text", text, mentions: [] }] } })
const took = (seq: number, turnId: string, clientRequestId: string) =>
  ({ seq, type: "turn/input/accepted", scope: { kind: "turn", turnId }, data: { providerThreadId: "p1", clientRequestId } })
const said = (seq: number, turnId: string, text: string) =>
  ({ seq, type: "item/completed", scope: { kind: "turn", turnId }, data: { providerThreadId: "p1", item: { type: "agentMessage", id: `${turnId}-i`, text } } })
const delta = (seq: number, turnId: string) =>
  ({ seq, type: "item/agentMessage/delta", scope: { kind: "turn", turnId }, data: { delta: "ki" } })

test("bb's log reads as each message it accepted and each reply, in its own turn", () => {
  const events = [
    said(41, "t2", "Apple. Mango. Pear."),
    took(33, "t2", "creq_note"),
    asked(32, "creq_note", "[bb system]\n\n@thread:thr_child completed", "system"),
    said(30, "t2", "Working on it."),
    delta(29, "t2"),
    took(26, "t2", "creq_fruit"),
    asked(25, "creq_fruit", "Name three fruits."),
    said(19, "t1", "ready"),
    took(3, "t1", "creq_ready"),
    asked(1, "creq_ready", "Reply with only the word ready."),
  ]
  assert.deepEqual(bbMessages(events), [
    { role: "user", text: "Reply with only the word ready.", turn: "t1" },
    { role: "agent", text: "ready", turn: "t1" },
    { role: "user", text: "Name three fruits.", turn: "t2" },
    { role: "agent", text: "Working on it.", turn: "t2" },
    { role: "user", text: "[bb system]\n\n@thread:thr_child completed", turn: "t2", mark: "system" },
    { role: "agent", text: "Apple. Mango. Pear.", turn: "t2" },
  ])
})

test("a message bb has not taken into a turn yet has no turn", () => {
  assert.deepEqual(bbMessages([asked(1, "creq_queued", "later")]), [{ role: "user", text: "later", turn: undefined }])
})
