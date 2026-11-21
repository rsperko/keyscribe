import assert from "node:assert/strict"
import { test } from "node:test"
import { exercises, type Context } from "./exercises.ts"
import type { AgentDriver, Message } from "./lib/driver.ts"
import type { Instance, TakeResult } from "./lib/instance.ts"
import { sha256 } from "./lib/util.ts"

function fakeContext(options: { turns?: boolean } = {}): Context & { silence: () => void } {
  const messages: Message[] = []
  let turns = 0
  let answering = true
  const agent = {
    kind: "fake", name: "kestrel", folder: "/fake", tool: undefined, conversation: "fake:1",
    addresses: { said: "fake 1", absent: "fake 9001" },
    owns: (conversation: string | undefined) => conversation === "fake:1",
    idle: async () => {},
    messages: async () => [...messages],
  } as unknown as AgentDriver
  const instance = {
    take(said: string): TakeResult {
      const address = ["kestrel", "fake 1"].find(name => said.startsWith(`tell ${name} `) || said.startsWith(`tell ${name}, `))
      if (!address) return { id: "t", ok: false }
      const body = said.slice(`tell ${address}`.length).replace(/^,? /, "")
      const turn = options.turns === false ? undefined : `turn${++turns}`
      messages.push({ role: "user", text: body, turn })
      if (answering) messages.push({ role: "agent", text: "ok", turn })
      return { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1", request: `request${++turns}`,
        reply: { kind: "answer", length: 2, sha256: sha256("ok") } }
    },
  } as unknown as Instance
  return { instance, agent, replyWait: 1, silence: () => { answering = false } }
}

test("every exercise passes again in a later round against the same conversation", async () => {
  const context = fakeContext()
  for (const round of [1, 2]) {
    for (const exercise of exercises) {
      await assert.doesNotReject(exercise.run(context), `${exercise.id} in round ${round}`)
    }
  }
})

for (const turns of [true, false]) {
  test(`a reply is checked against what the agent answered in this round, not an earlier one (${turns ? "with" : "without"} turn ids)`, async () => {
    const context = fakeContext({ turns })
    const reply = exercises.find(exercise => exercise.id === "R1")!
    await reply.run(context)
    context.silence()
    await assert.rejects(reply.run(context), /no reply in that turn/)
  })
}
