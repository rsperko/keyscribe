import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { exercises, type Context } from "./exercises.ts"
import type { AgentDriver, Message } from "./lib/driver.ts"
import type { Instance, TakeResult } from "./lib/instance.ts"
import { sha256 } from "./lib/util.ts"

const project = mkdtempSync(join(tmpdir(), "ks-fake-project-"))
process.on("exit", () => rmSync(project, { recursive: true, force: true }))

function fakeContext(options: {
  turns?: boolean; cue?: string; sentWhileDown?: boolean; endsBeforeSteering?: string; comments?: boolean; doubted?: boolean
  readTwice?: boolean; clipboardChanged?: boolean; historyLags?: boolean; hint?: string; unlisted?: boolean; keepsBehind?: boolean; declaresBehind?: "kept" | "sent"
  automatedTakesFront?: boolean; automatedHoldsBehind?: boolean; automatedStealsFocus?: boolean
  waits?: boolean; waitsButJoins?: boolean; ignoresBusy?: boolean; sendsAloneInFront?: boolean; awayUnlisted?: boolean; declaresFront?: "joined" | "alone"
} = {}): Context & { silence: () => void; automatedOpen: () => number; automatedKinds: string[] } {
  const messages: Message[] = []
  const records: any[] = []
  let turns = 0
  let answering = true
  let shown = false
  let front = false
  let automated = 0
  const opened: string[] = []
  let draft = ""
  const inFront = () => front && !(automated > 0 && options.automatedTakesFront)
  const sandboxed = (path: string) => { if (!path.startsWith(`${project}/`)) throw new Error(`the agent may write only inside its project, not ${path}`); writeFileSync(path, "") }
  let noting = false
  let clip = ""
  let down = false
  let running = true
  let busyTurn: string | undefined
  const ledger: { request?: string; read?: boolean; reason?: string; quiet?: boolean }[] = []
  const late: string[] = []
  let entries = 0
  const settle = () => {
    for (const entry of records.filter((candidate) => candidate.unsettled)) {
      delete entry.unsettled
      if (inFront() || (automated > 0 && options.automatedHoldsBehind)) {
        entry.steps = [{ text: "Not read aloud: kestrel was in front when it finished" }]
        ledger.push({ request: entry.request, read: false, reason: "its conversation was in front when it finished" }, { quiet: true })
      } else {
        entry.spoken_reply = { text: `kestrel${options.cue ?? ""}: ok` }
        ledger.push({ request: entry.request, read: true }, { quiet: true })
        if (options.readTwice) late.push(entry.request)
      }
      if (options.doubted) entry.summary = "May not have reached kestrel: check its terminal"
    }
    return records.filter((entry) => !(entry.lagging-- > 0))
  }
  const remember = (said: string, chosen: string, request?: string) => {
    const timestamp = new Date().toISOString()
    if (options.historyLags) {
      records.push({ id: `entry${++entries}`, heard: said, timestamp, facts: [{ label: "Chosen by", value: "Its name" }],
        steps: [{ text: "Not read aloud: something newer from kestrel replaced it" }], spoken_reply: { text: "kestrel: an earlier round" } })
    }
    const id = `entry${++entries}`
    records.push({ id, heard: said, timestamp, facts: [{ label: "Chosen by", value: chosen }], unsettled: !!request, request,
      lagging: options.historyLags ? 3 : 0 })
    return id
  }
  const answer = (said: string, rawBody: string, chosen: string): TakeResult => {
    const body = rawBody.replace("insert clipboard contents", clip)
    if (down) return options.sentWhileDown ? { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1" } : { id: "t", ok: false }
    const stoppable = body.match(/touch (\S+); sleep/)
    if (stoppable) {
      sandboxed(stoppable[1])
      busyTurn = `turn${++turns}`
      messages.push({ role: "user", text: body, turn: busyTurn })
      return { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1", history: remember(said, chosen) }
    }
    const gated = body.match(/touch (\S+); .*-f (\S+) \]/)
    if (gated) {
      sandboxed(gated[1])
      busyTurn = options.turns === false ? undefined : `turn${++turns}`
      messages.push({ role: "user", text: body, turn: busyTurn })
      if (options.comments) messages.push({ role: "agent", text: "I'll run that command now.", turn: busyTurn })
      if (options.endsBeforeSteering !== undefined) {
        if (options.endsBeforeSteering) messages.push({ role: "agent", text: options.endsBeforeSteering, turn: busyTurn })
        messages.push({ role: "ended", text: "", turn: busyTurn })
        busyTurn = undefined
      }
      return { id: "t", ok: true, receiptKind: "sent", conversation: "fake:1", history: remember(said, chosen) }
    }
    const waiting = options.waits && busyTurn !== undefined
    if (waiting && !options.waitsButJoins) {
      messages.push({ role: "ended", text: "", turn: busyTurn })
      busyTurn = undefined
    }
    const turn = busyTurn ?? (options.turns === false ? undefined : `turn${++turns}`)
    busyTurn = undefined
    messages.push({ role: "user", text: body, turn })
    if (noting) messages.push({ role: "user", text: "[app] a helper finished", turn, mark: "system" })
    noting = false
    const word = options.ignoresBusy || !/cherry/.test(body) ? "ok" : "cherry"
    if (answering) messages.push({ role: "agent", text: word, turn }, { role: "ended", text: "", turn })
    const request = `request${++turns}`
    const history = remember(said, chosen, request)
    return { id: "t", ok: true, receiptKind: waiting ? "queued" : "sent", conversation: "fake:1", request, history,
      reply: { kind: "answer", length: word.length, sha256: sha256(word) } }
  }
  let away = false
  const focused: string[] = []
  const agent = {
    kind: "fake", name: "kestrel", busyTake: options.waits ? "waits" : "joins", folder: "/fake", project, tool: undefined, conversation: "fake:1",
    addresses: { said: "fake 1", absent: "fake 9001" },
    owns: (conversation: string | undefined) => conversation === "fake:1",
    idle: async () => {},
    messages: async () => [...messages],
    window: {
      owns: (window: { spec: string }) => !options.unlisted && window.spec.startsWith("7:"),
      ...(options.unlisted ? { app: "dev.fake", focus: async () => { shown = true; front = true } } : {}),
      reopens: true,
      takeBehindDraft: options.declaresBehind ?? (options.keepsBehind ? "kept" : "sent"),
      takeInFrontOfDraft: options.declaresFront ?? (options.sendsAloneInFront ? "alone" : "joined"),
      show: async () => { shown = true },
      look: async () => ({ thread: shown, focused: shown && front, draft }),
      fill: async (text: string) => { draft += text },
      close: async () => { shown = false; front = false },
      openAutomated: async (kind: string) => {
        opened.push(kind)
        automated++
        if (options.automatedStealsFocus) front = false
        return async () => { automated-- }
      },
    },
    noteFromHost: async () => { noting = true },
    interrupt: async () => {
      messages.push({ role: "ended", text: "", turn: busyTurn })
      busyTurn = undefined
    },
    server: { stop: async () => { down = true }, start: async () => { down = false } },
  } as unknown as AgentDriver
  const instance = {
    windows: () => [{ app: "com.example.chat", spec: "6:cg:0", title: "Chat" }, { app: "dev.fake", spec: "7:cg:1", title: "" },
      ...(away && !options.awayUnlisted ? [{ app: "dev.away", spec: "8:cg:2", title: "away" }] : [])],
    focus: (spec: string) => {
      focused.push(spec)
      front = spec.startsWith("7:")
    },
    records: () => settle(),
    ledger: () => {
      const unsettled = records.some((entry) => entry.unsettled)
      settle()
      if (!unsettled) for (const request of late.splice(0)) ledger.push({ request, read: true }, { quiet: true })
      return [...ledger]
    },
    entry: (id: string) => settle().filter((entry) => entry.id === id).at(-1),
    quit: async () => { running = false },
    launch: async () => { running = true },
    connector: (action: string) => (action !== "status" && running
      ? { status: 1, stdout: "connector: the KeyScribe using it is running. Quit it first", stderr: "" }
      : { status: 0, stdout: "", stderr: "" }),
    take(said: string): TakeResult {
      if (said === "check on kestrel") return { id: "t", ok: true, conversation: "fake:1" }
      if (said === "check on this conversation") return front ? { id: "t", ok: true, conversation: "fake:1" } : { id: "t", ok: false }
      if (said === "go to kestrel") {
        shown = true
        front = true
        return { id: "t", ok: true, conversation: "fake:1" }
      }
      if (said === "open kestrel") {
        shown = true
        front = true
        return { id: "t", ok: true }
      }
      const address = ["please tell kestrel", "tell kestrel", "tell fake 1", "ask kestrel", "kestrel"].find(name => said.startsWith(`${name} `) || said.startsWith(`${name}, `))
      if (address && draft && !front && options.keepsBehind) {
        return { id: "t", ok: false, receiptKind: "kept", conversation: "fake:1", history: remember(said, "Its name"),
          hud: "advisory(message: \"Not sent to kestrel: its prompt box already has text. Send or clear that text there, then say this again\")" }
      }
      if (address) return answer(said, said.slice(address.length).replace(/^,? /, ""), "Its name")
      if (front && said.startsWith("tell kestrol ")) return answer(said, said.slice("tell kestrol ".length), "Sounded like its name")
      if (!inFront() || said.startsWith("tell ")) return { id: "t", ok: false }
      const joins = draft && !options.sendsAloneInFront
      const body = joins ? `${draft} ${said}` : said
      if (joins) draft = options.hint ?? ""
      return answer(said, body, "The conversation in front")
    },
  } as unknown as Instance
  const clipboard = {
    set: (kind: "text" | "image", value?: string) => { clip = kind === "image" ? "/tmp/keyscribe/clipboard-1.png" : value ?? "" },
    keep: async <T,>(work: (mark: () => () => boolean) => Promise<T>) => {
      const saved = clip
      try {
        return await work(() => { const marked = clip; return () => !options.clipboardChanged && clip === marked })
      } finally { clip = saved }
    },
  }
  const lookAway = {
    ...(options.awayUnlisted ? { focus: async () => { focused.push("away"); front = false } } : {}),
    show: async () => { away = true },
    owns: (window: { spec: string }) => window.spec.startsWith("8:"),
    close: async () => { away = false },
  }
  return { instance, agent, away: lookAway, focused, replyWait: 1, clipboard, holdSeconds: 0, settleSeconds: 0, silence: () => { answering = false }, automatedOpen: () => automated, automatedKinds: opened }
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

test("a take the app says may not have reached the agent fails even though the agent recorded it", async () => {
  for (const id of ["D1", "N11", "N12", "D12"]) {
    await assert.rejects(exercises.find((exercise) => exercise.id === id)!.run(fakeContext({ doubted: true })), /may not have reached/, id)
  }
})

test("copying something said as the clipboard's contents fails when the clipboard is not put back exactly", async () => {
  for (const id of ["I1", "I2"]) {
    await assert.rejects(exercises.find((exercise) => exercise.id === id)!.run(fakeContext({ clipboardChanged: true })), /put back exactly/, id)
  }
})

test("a reply kept as read more than once fails", async () => {
  for (const id of ["B8", "D12"]) {
    await assert.rejects(exercises.find((exercise) => exercise.id === id)!.run(fakeContext({ readTwice: true })), /was read 2 times/, id)
  }
})

test("each take's reply is judged by its own request and its own History entry, even when an earlier round said the same and History lags", async () => {
  const context = fakeContext({ historyLags: true })
  for (const id of ["B8", "D9", "D12", "D14", "R7"]) {
    await assert.doesNotReject(exercises.find((exercise) => exercise.id === id)!.run(context), id)
  }
})

test("a hint the agent shows in its empty box once the draft is sent does not count as the draft left behind", async () => {
  await assert.doesNotReject(exercises.find((exercise) => exercise.id === "D10")!.run(fakeContext({ hint: 'Try "write a test for half a"' })))
})

test("a window the instance cannot list is brought forward by its own driver", async () => {
  const context = fakeContext({ unlisted: true })
  for (const id of ["D9", "D10", "D12", "D13", "N14"]) {
    await assert.doesNotReject(exercises.find((exercise) => exercise.id === id)!.run(context), id)
  }
})

test("a near-miss name is judged with another app in front, since one that sounds like the conversation in front is sent there", async () => {
  const context = fakeContext()
  await exercises.find((exercise) => exercise.id === "N14")!.run(context)
  await assert.doesNotReject(exercises.find((exercise) => exercise.id === "N13")!.run(context))
})

for (const [keepsBehind, declaresBehind, passes] of [[true, "kept", true], [false, "sent", true], [true, "sent", false], [false, "kept", false]] as const) {
  test(`a take behind a draft that is ${keepsBehind ? "kept" : "sent"} where the agent's window says ${declaresBehind} ${passes ? "passes" : "fails"} D10, and the draft stays`, async () => {
    const run = exercises.find((exercise) => exercise.id === "D10")!.run(fakeContext({ keepsBehind, declaresBehind }))
    if (passes) await assert.doesNotReject(run)
    else await assert.rejects(run, /the take behind/)
  })
}

for (const [options, failure] of [[{}, undefined], [{ automatedTakesFront: true }, /went to/], [{ automatedHoldsBehind: true }, /reply behind was not read/], [{ automatedStealsFocus: true }, undefined]] as const) {
  test(`D15 ${failure ? `fails with ${failure}` : "passes"} for ${JSON.stringify(options)}, opens each kind of automated page and closes it either way`, async () => {
    const context = fakeContext(options)
    const run = exercises.find((exercise) => exercise.id === "D15")!.run(context)
    if (failure) await assert.rejects(run, failure)
    else {
      await assert.doesNotReject(run)
      assert.deepEqual(context.automatedKinds, ["webdriver", "headless"])
    }
    assert.equal(context.automatedOpen(), 0)
  })
}

test("D15 applies only to an agent whose window can open an automated page", () => {
  const automated = exercises.find((exercise) => exercise.id === "D15")!
  const { agent } = fakeContext()
  assert.equal(automated.applies!(agent), true)
  assert.equal(automated.applies!({ ...agent, window: { ...agent.window!, openAutomated: undefined } } as AgentDriver), false)
  assert.equal(automated.applies!({ ...agent, window: undefined } as AgentDriver), false)
})

test("to look away the run brings forward a window it opened itself, never another app's window that might be marked read", async () => {
  const context = fakeContext() as ReturnType<typeof fakeContext> & { focused: string[] }
  for (const id of ["D9", "D10", "N8", "N14"]) {
    await assert.doesNotReject(exercises.find((exercise) => exercise.id === id)!.run(context), id)
  }
  assert.ok(context.focused.includes("8:cg:2"))
  assert.ok(!context.focused.includes("6:cg:0"))
})

test("an agent that declares a take while busy waits for the running turn passes D2 only when the app says it waits and the take arrives after that turn", async () => {
  const busy = exercises.find((exercise) => exercise.id === "D2")!
  await assert.doesNotReject(busy.run(fakeContext({ waits: true })))
  await assert.rejects(busy.run(fakeContext({ waits: true, waitsButJoins: true })), /before the running turn ended/)
})

test("a take while busy that the agent records but does not follow fails D2", async () => {
  const busy = exercises.find((exercise) => exercise.id === "D2")!
  await assert.rejects(busy.run(fakeContext({ ignoresBusy: true })), /did not follow the take while busy/)
  await assert.rejects(busy.run(fakeContext({ waits: true, ignoresBusy: true })), /did not follow the take while busy/)
})

for (const [sendsAloneInFront, declaresFront, passes] of [[false, "joined", true], [true, "alone", true], [true, "joined", false], [false, "alone", false]] as const) {
  test(`a take in front of a draft that is ${sendsAloneInFront ? "sent alone" : "joined"} where the agent's window says ${declaresFront} ${passes ? "passes" : "fails"} D10`, async () => {
    const run = exercises.find((exercise) => exercise.id === "D10")!.run(fakeContext({ sendsAloneInFront, declaresFront }))
    if (passes) await assert.doesNotReject(run)
    else await assert.rejects(run, /the take in front/)
  })
}

test("a look-away window the instance lists without its title is brought forward by its own driver", async () => {
  const context = fakeContext({ awayUnlisted: true }) as ReturnType<typeof fakeContext> & { focused: string[] }
  for (const id of ["D9", "D10", "N8"]) {
    await assert.doesNotReject(exercises.find((exercise) => exercise.id === id)!.run(context), id)
  }
  assert.ok(context.focused.includes("away"))
  assert.ok(!context.focused.includes("6:cg:0"))
})
