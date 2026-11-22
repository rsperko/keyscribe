import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { test } from "node:test"
import { exercises, type Context } from "./exercises.ts"
import type { AgentDriver, Message } from "./lib/driver.ts"
import type { Instance, TakeResult } from "./lib/instance.ts"
import { sha256 } from "./lib/util.ts"

function fakeContext(options: { turns?: boolean; cue?: string; sentWhileDown?: boolean; endsBeforeSteering?: string; comments?: boolean } = {}): Context & { silence: () => void } {
  const messages: Message[] = []
  const records: any[] = []
  let turns = 0
  let answering = true
  let shown = false
  let front = false
  let draft = ""
  let noting = false
  let clip = ""
  let down = false
  let busyTurn: string | undefined
  const answer = (said: string, rawBody: string, chosen: string): TakeResult => {
    const body = rawBody.replace("insert clipboard contents", clip)
    if (down) return options.sentWhileDown ? { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1" } : { id: "t", ok: false }
    const gated = body.match(/touch (\S+); .*-f (\S+) \]/)
    if (gated) {
      writeFileSync(gated[1], "")
      busyTurn = options.turns === false ? undefined : `turn${++turns}`
      messages.push({ role: "user", text: body, turn: busyTurn })
      if (options.comments) messages.push({ role: "agent", text: "I'll run that command now.", turn: busyTurn })
      if (options.endsBeforeSteering !== undefined) {
        if (options.endsBeforeSteering) messages.push({ role: "agent", text: options.endsBeforeSteering, turn: busyTurn })
        messages.push({ role: "ended", text: "", turn: busyTurn })
        busyTurn = undefined
      }
      return { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1" }
    }
    const turn = busyTurn ?? (options.turns === false ? undefined : `turn${++turns}`)
    busyTurn = undefined
    messages.push({ role: "user", text: body, turn })
    if (noting) messages.push({ role: "user", text: "[app] a helper finished", turn, mark: "system" })
    noting = false
    if (answering) messages.push({ role: "agent", text: "ok", turn }, { role: "ended", text: "", turn })
    records.push({ heard: said, facts: [{ label: "Chosen by", value: chosen }],
      ...(front ? { steps: [{ text: "Not read aloud: kestrel was in front when it finished" }] } : { spoken_reply: { text: `kestrel${options.cue ?? ""}: ok` } }) })
    return { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1", request: `request${++turns}`,
      reply: { kind: "answer", length: 2, sha256: sha256("ok") } }
  }
  const agent = {
    kind: "fake", name: "kestrel", folder: "/fake", tool: undefined, conversation: "fake:1",
    addresses: { said: "fake 1", absent: "fake 9001" },
    owns: (conversation: string | undefined) => conversation === "fake:1",
    idle: async () => {},
    messages: async () => [...messages],
    window: {
      pids: () => [7],
      show: async () => { shown = true },
      look: async () => ({ thread: shown, focused: shown && front, draft }),
      fill: async (text: string) => { draft += text },
      close: async () => { shown = false; front = false },
    },
    noteFromHost: async () => { noting = true },
    server: { stop: async () => { down = true }, start: async () => { down = false } },
  } as unknown as AgentDriver
  const instance = {
    windows: () => [{ app: "dev.fake", spec: "7:cg:1", title: "" }, { app: "com.example.other", spec: "8:cg:2", title: "" }],
    focus: (spec: string) => { front = spec.startsWith("7:") },
    record: (text: string) => records.filter(entry => entry.heard === text || entry.heard.endsWith(text)).at(-1),
    take(said: string): TakeResult {
      if (said === "open kestrel") {
        shown = true
        front = true
        return { id: "t", ok: true }
      }
      const address = ["tell kestrel", "tell fake 1", "ask kestrel"].find(name => said.startsWith(`${name} `) || said.startsWith(`${name}, `))
      if (address) return answer(said, said.slice(address.length).replace(/^,? /, ""), "Its name")
      if (!front || said.startsWith("tell ")) return { id: "t", ok: false }
      const body = draft ? `${draft} ${said}` : said
      draft = ""
      return answer(said, body, "The conversation in front")
    },
  } as unknown as Instance
  const clipboard = {
    set: (kind: "text" | "image", value?: string) => { clip = kind === "image" ? "/tmp/keyscribe/clipboard-1.png" : value ?? "" },
    keep: async <T,>(work: () => Promise<T>) => { const saved = clip; try { return await work() } finally { clip = saved } },
  }
  return { instance, agent, replyWait: 1, clipboard, holdSeconds: 0, silence: () => { answering = false } }
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

test("a reply read as answering someone else fails the check for the app's own note", async () => {
  const context = fakeContext({ cue: ", answering someone else" })
  const note = exercises.find(exercise => exercise.id === "R7")!
  await assert.rejects(note.run(context), /answering someone else/)
})

test("a take to an unreachable app that reads as sent fails its check", async () => {
  const unreachable = exercises.find(exercise => exercise.id === "C1")!
  await assert.rejects(unreachable.run(fakeContext({ sentWhileDown: true })), /read as sent/)
})

for (const [ending, said] of [["a ready answer", "Ready."], ["another answer", "Done"], ["formatted ready", "**ready**"], ["an error with no reply", ""]]) {
  test(`a take while busy that reaches the agent only after its running turn ended with ${ending} fails D2`, async () => {
    const busy = exercises.find((exercise) => exercise.id === "D2")!
    await assert.rejects(busy.run(fakeContext({ endsBeforeSteering: said })), /only after the running turn had ended/)
    await assert.rejects(busy.run(fakeContext({ comments: true, endsBeforeSteering: said })), /only after the running turn had ended/)
  })
}

test("commentary before the blocked command does not end the running turn", async () => {
  const busy = exercises.find((exercise) => exercise.id === "D2")!
  await assert.doesNotReject(busy.run(fakeContext({ comments: true })))
})
