import { automatedKinds, type AgentDriver, type Message } from "./lib/driver.ts"
import type { Instance, TakeResult } from "./lib/instance.ts"
import { spawn } from "node:child_process"
import { existsSync, mkdtempSync, rmSync } from "node:fs"
import { join } from "node:path"
import { sha256, sleep, until } from "./lib/util.ts"

export type Clipboard = { set(kind: "text" | "image", value?: string): void; keep<T>(work: (mark: () => () => boolean) => Promise<T>): Promise<T> }
export type Context = { instance: Instance; agent: AgentDriver; replyWait: number; clipboard: Clipboard; holdSeconds?: number; settleSeconds?: number }
export type Exercise = {
  id: string
  title: string
  applies?: (agent: AgentDriver) => boolean
  run: (context: Context) => Promise<void>
}

class Failed extends Error {}
const check = (condition: unknown, why: string) => { if (!condition) throw new Failed(why) }
const plain = (text: string) => text.replace(/[\u200B-\u200D\u2060\uFEFF]/g, "").trim()
const users = (messages: Message[], text: string) => messages.filter((message) => message.role === "user" && plain(message.text) === text)
const show = (result: TakeResult) => JSON.stringify(result)

const doubted = /may not have reached/i

function historyOf(context: Context, said: string, result: TakeResult) {
  check(result.history, `the take for "${said}" reported no History entry: ${show(result)}`)
  return until(`the History entry for "${said}"`, () => context.instance.entry(result.history!), 15, 250)
}

async function withoutDoubt(context: Context, said: string, result: TakeResult) {
  check(!doubted.test(result.hud ?? ""), `the take said it may not have reached the agent: ${show(result)}`)
  const entry = await historyOf(context, said, result)
  check(!doubted.test(JSON.stringify(entry)), `History says the take may not have reached the agent: ${JSON.stringify(entry)}`)
}

function take(context: Context, said: string, options: { waitReply?: number; timeout?: number } = {}) {
  return context.instance.take(said, options)
}

async function deliverAndRead(context: Context, body: string, options: { said?: string; asSaid?: boolean } = {}) {
  const said = options.said ?? `tell ${context.agent.name} ${body}`
  const { agent } = context
  const since = (await agent.messages()).length
  const result = take(context, said, { waitReply: context.replyWait })
  check(result.ok, `the take was not delivered: ${show(result)}`)
  check(result.receiptKind === "sent", `expected a sent receipt: ${show(result)}`)
  check(agent.owns(result.conversation), `delivered to ${result.conversation}, expected ${agent.conversation}`)
  await agent.idle(context.replyWait)
  const messages = await agent.messages()
  const fresh = messages.slice(since)
  if (options.asSaid !== false) check(users(fresh, body).length === 1, `the agent recorded ${users(fresh, body).length} user messages "${body}"`)
  await withoutDoubt(context, said, result)
  return { result, messages, since, fresh, said }
}

async function unnamed(context: Context, body: string, options: { waitReply?: number } = { waitReply: context.replyWait }) {
  const { agent } = context
  const since = (await agent.messages()).length
  const result = take(context, body, options)
  check(result.ok && agent.owns(result.conversation), `the take went to ${result.conversation}: ${show(result)}`)
  await agent.idle(context.replyWait)
  check(users((await agent.messages()).slice(since), body).length === 1, `the agent has no user message "${body}"`)
  await withoutDoubt(context, body, result)
  return result
}

function nearMiss(name: string) {
  const vowel = [...name].findLastIndex((letter) => "aeiou".includes(letter))
  return `${name.slice(0, vowel)}${name[vowel] === "o" ? "a" : "o"}${name.slice(vowel + 1)}`
}

async function replyOutcome(context: Context, said: string, result: TakeResult) {
  const request = result.request
  check(request, `the take for "${said}" reported no request to tell its reply by`)
  const settledAt = () => {
    const lines = context.instance.ledger()
    return lines.some((line) => line.request === request) && lines.at(-1)?.quiet ? lines.length : undefined
  }
  const waiting = `the reply to "${said}" read aloud or the reason it was not, with nothing left to read`
  let length = await until(waiting, settledAt, 90, 250)
  for (let looks = 0; ; looks++) {
    await sleep((context.settleSeconds ?? 1) * 1000)
    const again = await until(waiting, settledAt, 90, 250)
    if (again === length) break
    check(looks < 20, `the reading of replies never stayed quiet after the reply to "${said}"`)
    length = again
  }
  const mine = context.instance.ledger().filter((line) => line.request === request)
  const reads = mine.filter((line) => line.read).length
  const unread = mine.flatMap((line) => (line.read ? [] : [line.reason ?? ""]))
  check(reads + unread.length === 1, `the reply to "${said}" was read ${reads} times and reported unread ${unread.length} times (${unread.join("; ")})`)
  check(result.history, `the take for "${said}" reported no History entry: ${show(result)}`)
  const entry = await until(`History keeping what became of the reply to "${said}"`, () => {
    const current = context.instance.entry(result.history!)
    const kept = reads ? current?.spoken_reply?.text : current?.steps?.some((step: any) => /^Not read aloud/.test(step.text))
    return kept ? current : undefined
  }, 15, 250)
  return { read: reads === 1, reason: unread[0], entry }
}

async function bringForward(context: Context) {
  const { instance, agent } = context
  const window = agent.window!
  await window.show()
  if (window.focus) await window.focus()
  else instance.focus(await until("a window of the agent's app", () => instance.windows().find((w) => window.owns(w))?.spec, 30, 500))
  await until("the conversation in front", async () => ((await window.look()).focused ? true : undefined), 15, 500)
}

async function takeInFront(context: Context, body: string) {
  const result = await unnamed(context, body)
  const outcome = await replyOutcome(context, body, result)
  const chosen = outcome.entry.facts?.find((fact: any) => fact.label === "Chosen by")?.value
  check(chosen === "The conversation in front", `the take was chosen by ${chosen}`)
  check(!outcome.read && /in front/.test(outcome.reason ?? ""), `the reply was not held back for being in front: ${outcome.reason ?? "it was read"}`)
}

async function lookAway(context: Context) {
  const { instance, agent } = context
  const listed = instance.windows()
  const ours = agent.window!.app ?? listed.find((w) => agent.window!.owns(w))?.app
  const others = listed.filter((w) => !agent.window!.owns(w) && !w.app.startsWith("com.keyscribe."))
  const other = others.find((w) => w.app !== ours) ?? (agent.window!.app === undefined ? others[0] : undefined)
  check(other, "the run needs another app's window to move focus to")
  instance.focus(other!.spec)
  await until("the conversation no longer in front", async () => (!(await agent.window!.look()).focused ? true : undefined), 15, 250)
}

export const exercises: Exercise[] = [
  {
    id: "D1",
    title: "An idle conversation gets the take once, as the user's message",
    async run(context) {
      const body = "Reply with only the word kiwi."
      const { fresh } = await deliverAndRead(context, body)
      const sent = users(fresh, body)
      check(sent.length === 1, `the agent recorded ${sent.length} user messages "${body}"`)
    },
  },
  {
    id: "R1",
    title: "The reply read for a take is the reply the agent gave to that take",
    async run(context) {
      const body = "Reply with only the word mango."
      const { result, fresh } = await deliverAndRead(context, body)
      check(result.reply, `no reply was reported: ${result.replyProblem ?? show(result)}`)
      const asked = users(fresh, body).at(-1)
      check(asked, "the agent has no record of the take")
      const answer = fresh.filter((message) => message.role === "agent" && message.turn === asked!.turn).at(-1)
      check(answer, "the agent recorded no reply in that turn")
      check(result.reply!.kind === "answer", `the turn ended as ${result.reply!.kind}: ${result.reply!.ending ?? ""}`)
      check(result.reply!.sha256 === sha256(answer!.text),
        `the reply read (length ${result.reply!.length}) is not the agent's reply (length ${answer!.text.length})`)
    },
  },
  {
    id: "D6",
    title: "A take starting with a slash arrives as text, not as a command",
    async run(context) {
      const body = "/status"
      const { fresh } = await deliverAndRead(context, body)
      check(users(fresh, body).length === 1, `the agent has no user message "${body}"; it may have run as a command`)
    },
  },
  {
    id: "D8",
    title: "Two identical takes arrive as two messages, each matched to its own request",
    async run(context) {
      const body = "Reply with only the word plum."
      const first = await deliverAndRead(context, body)
      const second = await deliverAndRead(context, body)
      check(first.result.request !== second.result.request, "both takes report the same request")
      const both = users(second.messages.slice(first.since), body).length
      check(both === 2, `the agent recorded ${both} messages "${body}"`)
    },
  },
  {
    id: "N4",
    title: "A name no conversation has holds the take and sends nothing",
    async run(context) {
      const before = (await context.agent.messages()).length
      const result = context.instance.take("tell zebrafinch reply with only the word nope")
      check(!result.ok, `a take to an unknown name was delivered: ${show(result)}`)
      check(result.conversation === undefined, `a take to an unknown name went to ${result.conversation}`)
      check((await context.agent.messages()).length === before, "the agent recorded a new message")
    },
  },
  {
    id: "N5",
    title: "A number right after a conversation's name, with no address of its own, is the start of the message",
    async run(context) {
      const body = "2 things are broken. Reply with only the word fig."
      const { fresh } = await deliverAndRead(context, body)
      check(users(fresh, body).length === 1, `the agent has no user message "${body}"`)
    },
  },
  {
    id: "N6",
    title: "A conversation's own address in its app reaches it, said with or without a comma",
    applies: (agent) => agent.addresses !== undefined,
    async run(context) {
      const { agent } = context
      for (const [said, body] of [
        [`tell ${agent.addresses!.said} Reply with only the word lime.`, "Reply with only the word lime."],
        [`tell ${agent.addresses!.said}, reply with only the word pear.`, "reply with only the word pear."],
      ]) {
        await deliverAndRead(context, body, { said })
      }
    },
  },
  {
    id: "N7",
    title: "An address in the app that names no conversation holds, never reaching a shorter name",
    applies: (agent) => agent.addresses !== undefined,
    async run(context) {
      const { instance, agent } = context
      const before = (await agent.messages()).length
      for (const said of [`tell ${agent.addresses!.absent} reply with only the word nope`, `tell ${agent.addresses!.absent}, reply with only the word nope`]) {
        const result = instance.take(said)
        check(!result.ok && result.conversation === undefined, `"${said}" was delivered: ${show(result)}`)
      }
      check((await agent.messages()).length === before, "the agent recorded a new message")
    },
  },
  {
    id: "D9",
    title: "A take with no name goes to the conversation in front, and its reply is not read over it",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      await bringForward(context)
      await takeInFront(context, "Reply with only the word quince.")
    },
  },
  {
    id: "D15",
    title: "A page an automated browser opens on the same app never takes over from the conversation in front, and replies behind are still read while it is open",
    applies: (agent) => agent.window?.openAutomated !== undefined,
    async run(context) {
      const { agent } = context
      const window = agent.window!
      for (const kind of automatedKinds) {
        await bringForward(context)
        const close = await window.openAutomated!(kind)
        try {
          check((await window.look()).focused, `the conversation was no longer in front once the ${kind} page opened`)
          await takeInFront(context, `Reply with only the word ${kind === "webdriver" ? "guava" : "papaya"}.`)
          await lookAway(context)
          const body = `Reply with only the word ${kind === "webdriver" ? "lychee" : "durian"}.`
          const { result, said } = await deliverAndRead(context, body)
          const outcome = await replyOutcome(context, said, result)
          check(outcome.read, `the reply behind was not read while the ${kind} page was open: ${outcome.reason}`)
        } finally {
          await close()
        }
      }
    },
  },
  {
    id: "D10",
    title: "A draft in the box of the conversation in front is sent with the take, and one in a box behind is left exactly as it was while the take behind is kept or sent alone, as the agent's window declares",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      const window = agent.window!
      await bringForward(context)
      const draft = "half a thought,"
      await window.fill(draft)
      await lookAway(context)
      const behind = "Reply with only the word fig."
      const before = (await agent.messages()).length
      const named = take(context, `tell ${agent.name} ${behind}`, { waitReply: context.replyWait })
      const expected = window.takeBehindDraft
      check(named.receiptKind === expected, `the take behind was ${named.receiptKind ?? "neither sent nor kept"} where ${agent.kind} ${expected === "kept" ? "keeps it" : "sends it alone"}: ${show(named)}`)
      if (expected === "kept") {
        check(/prompt box already has text/.test(named.hud ?? ""), `the take behind was kept for another reason: ${show(named)}`)
        check(users((await agent.messages()).slice(before), behind).length === 0, `the take behind was reported kept but sent: ${show(named)}`)
      } else {
        check(agent.owns(named.conversation), `the take behind went to ${named.conversation}: ${show(named)}`)
        await agent.idle(context.replyWait)
        check(users((await agent.messages()).slice(before), behind).length === 1, `the take behind was not sent alone as "${behind}"`)
        await withoutDoubt(context, behind, named)
      }
      check((await window.look()).draft?.includes(draft), "the draft in the box behind was not left in place")
      await bringForward(context)
      const body = "reply with only the word olive."
      const since = (await agent.messages()).length
      const result = take(context, body, { waitReply: context.replyWait })
      check(result.ok && agent.owns(result.conversation), `the take went to ${result.conversation}: ${show(result)}`)
      await agent.idle(context.replyWait)
      await withoutDoubt(context, body, result)
      const joined = `${draft} ${body}`
      check(users((await agent.messages()).slice(since), joined).length === 1, `the agent has no user message "${joined}"`)
      check(!(await window.look()).draft?.includes(draft), "the draft is still in the box after it was sent")
    },
  },
  {
    id: "N8",
    title: "Open brings the named conversation forward in its app",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      await bringForward(context)
      await lookAway(context)
      const result = instance.take(`open ${agent.name}`)
      check(result.ok, `open did not succeed: ${show(result)}`)
      await until("the conversation in front of its app", async () => ((await agent.window!.look()).focused ? true : undefined), 15, 500)
    },
  },
  {
    id: "D2",
    title: "A take while the agent works reaches the running turn, and the reply read is its last answer",
    async run(context) {
      const { instance, agent } = context
      const gate = mkdtempSync(join(agent.project, ".ks-busy-"))
      const started = join(gate, "started")
      const release = join(gate, "release")
      const working = "Use your shell tool to run this exact command, then reply with only the word ready: "
        + `touch ${started}; i=0; while [ ! -f ${release} ] && [ $i -lt 900 ]; do sleep 0.2; i=$((i+1)); done`
      const later = "When the command finishes, reply with only the word cherry."
      try {
        if (agent.window) await lookAway(context)
        const since = (await agent.messages()).length
        const first = take(context, `tell ${agent.name} ${working}`)
        check(first.ok && agent.owns(first.conversation), `the first take went to ${first.conversation}: ${show(first)}`)
        await until("the agent running the first take's command", async () => (existsSync(started) ? true : undefined), 90, 250)
        spawn("/bin/sh", ["-c", `sleep ${context.holdSeconds ?? 15}; touch '${release}'`], { detached: true, stdio: "ignore" }).unref()
        const result = take(context, `tell ${agent.name} ${later}`, { waitReply: context.replyWait + 30 })
        check(result.ok && agent.owns(result.conversation), `the take while busy went to ${result.conversation}: ${show(result)}`)
        await agent.idle(context.replyWait + 30)
        await withoutDoubt(context, `tell ${agent.name} ${working}`, first)
        await withoutDoubt(context, `tell ${agent.name} ${later}`, result)
        const fresh = (await agent.messages()).slice(since)
        check(users(fresh, working).length === 1 && users(fresh, later).length === 1, "the agent did not record each take once")
        const asked = fresh.indexOf(users(fresh, working)[0])
        const ended = fresh.findIndex((message, index) => index > asked && message.role === "ended")
        const steered = fresh.indexOf(users(fresh, later)[0])
        check(ended !== -1, "the agent's own record never shows the running turn ending")
        check(steered < ended, "the take while busy reached the agent only after the running turn had ended")
        const last = fresh.filter((message) => message.role === "agent").at(-1)
        check(result.reply && last && result.reply.sha256 === sha256(last.text), `the reply read is not the agent's last answer: ${show(result)}`)
      } finally {
        rmSync(gate, { recursive: true, force: true })
      }
    },
  },
  {
    id: "D11",
    title: "A long take arrives whole",
    async run(context) {
      const body = `Read this sample: ${"plum orchard ".repeat(250).trim()}. Reply with only the word long.`
      const { fresh } = await deliverAndRead(context, body)
      check(users(fresh, body).length === 1, `the agent has no single user message with the whole take (${body.length} characters)`)
    },
  },
  {
    id: "N9",
    title: "Ask reaches the named conversation like tell",
    async run(context) {
      const body = "Reply with only the word lime."
      await deliverAndRead(context, body, { said: `ask ${context.agent.name}, ${body}` })
    },
  },
  {
    id: "I1",
    title: "Copied text said as the clipboard's contents arrives as that text",
    async run(context) {
      const token = `clip${Date.now().toString(36)}`
      await context.clipboard.keep(async (mark) => {
        context.clipboard.set("text", token)
        const unchanged = mark()
        const { fresh } = await deliverAndRead(context, "Reply with only the word ready about insert clipboard contents.", { asSaid: false })
        check(fresh.some((message) => message.role === "user" && message.text.includes(token)), `the agent has no user message with the copied text ${token}`)
        check(unchanged(), "the clipboard was not put back exactly as it was")
      })
    },
  },
  {
    id: "I2",
    title: "A copied image said as the clipboard's contents reaches the agent as a saved file's path",
    async run(context) {
      await context.clipboard.keep(async (mark) => {
        context.clipboard.set("image")
        const unchanged = mark()
        const { fresh } = await deliverAndRead(context, "Reply with only the word picture about insert clipboard contents.", { asSaid: false })
        check(fresh.some((message) => message.role === "user" && /\/[^\s]+\.png\b/.test(message.text)), "the agent has no user message with the image's path")
        check(unchanged(), "the clipboard was not put back exactly as it was")
      })
    },
  },
  {
    id: "N10",
    title: "Open brings the conversation forward even when its app has no window open",
    applies: (agent) => agent.window?.reopens === true,
    async run(context) {
      const { instance, agent } = context
      await bringForward(context)
      await agent.window!.close()
      await lookAway(context)
      const result = instance.take(`open ${agent.name}`, { timeout: 45 })
      check(result.ok, `open did not succeed: ${show(result)}`)
      await until("the conversation in front of a reopened window", async () => ((await agent.window!.look()).focused ? true : undefined), 30, 500)
    },
  },
  {
    id: "R7",
    title: "A reply to a dictation is read as its answer even when the agent's app adds its own note to the turn",
    applies: (agent) => agent.noteFromHost !== undefined,
    async run(context) {
      const { agent } = context
      if (agent.window) await lookAway(context)
      for (let attempt = 1; ; attempt++) {
        const body = `Use your shell tool to run the command \`sleep 25\`, then reply with only the word apricot${attempt}.`
        await agent.noteFromHost!()
        const { result, fresh, said } = await deliverAndRead(context, body)
        const asked = fresh.find((message) => message.role === "user" && plain(message.text) === body)
        const noted = fresh.some((message) => message.mark && message.turn !== undefined && message.turn === asked?.turn)
        const answered = fresh.some((message) => message.role === "agent" && message.turn === asked?.turn)
        if (!noted || !answered || !result.reply) {
          check(attempt < 3, "the app's note never joined a dictated turn that the agent answered, so this run could not test it")
          continue
        }
        const outcome = await replyOutcome(context, said, result)
        check(outcome.read, `the reply was not read: ${outcome.reason}`)
        const read: string = outcome.entry.spoken_reply.text
        check(!/answering someone else/i.test(read), `the reply was read as answering someone else: ${read}`)
        return
      }
    },
  },
  {
    id: "B8",
    title: "Two takes in a row each get their reply read, or History says why it was not",
    async run(context) {
      const first = "Reply with a four sentence story about a fox."
      const second = "Reply with only the word pear."
      if (context.agent.window) await lookAway(context)
      const takes = [await deliverAndRead(context, first), await deliverAndRead(context, second)]
      for (const delivered of takes) await replyOutcome(context, delivered.said, delivered.result)
    },
  },
  {
    id: "D12",
    title: "A reply to a take sent to the conversation in front is read aloud when another app is in front as it finishes",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      await bringForward(context)
      const body = "Use your shell tool to run the command `sleep 8`, then reply with only the word plum."
      const result = take(context, body)
      check(result.ok && context.agent.owns(result.conversation), `the take went to ${result.conversation}: ${show(result)}`)
      await lookAway(context)
      await context.agent.idle(context.replyWait)
      await withoutDoubt(context, body, result)
      const outcome = await replyOutcome(context, body, result)
      check(outcome.read, `the reply was not read with another app in front: ${outcome.reason}`)
    },
  },
  {
    id: "D13",
    title: "Checking on the conversation in front and then speaking to it both reach it",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      await bringForward(context)
      const checked = instance.take("check on this conversation")
      check(checked.ok && agent.owns(checked.conversation), `the check went to ${checked.conversation}: ${show(checked)}`)
      await unnamed(context, "Reply with only the word cedar.")
    },
  },
  {
    id: "N11",
    title: "A conversation's name said first, then a comma, reaches it",
    async run(context) {
      const body = "reply with only the word birch."
      await deliverAndRead(context, body, { said: `${context.agent.name}, ${body}` })
    },
  },
  {
    id: "N12",
    title: "Please tell reaches the named conversation like tell",
    async run(context) {
      const body = "Reply with only the word maple."
      await deliverAndRead(context, body, { said: `please tell ${context.agent.name} ${body}` })
    },
  },
  {
    id: "N13",
    title: "A name one sound away from a conversation's name holds the take and sends nothing while another app is in front",
    async run(context) {
      if (context.agent.window) await lookAway(context)
      const before = (await context.agent.messages()).length
      const result = context.instance.take(`tell ${nearMiss(context.agent.name)} reply with only the word nope`)
      check(!result.ok && result.conversation === undefined, `a take to a near-miss name was delivered: ${show(result)}`)
      check((await context.agent.messages()).length === before, "the agent recorded a new message")
    },
  },
  {
    id: "N14",
    title: "Go to brings the named conversation forward in its app",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      await bringForward(context)
      await lookAway(context)
      const result = instance.take(`go to ${agent.name}`)
      check(result.ok && agent.owns(result.conversation), `go to did not reach the conversation: ${show(result)}`)
      await until("the conversation in front of its app", async () => ((await agent.window!.look()).focused ? true : undefined), 15, 500)
    },
  },
  {
    id: "D14",
    title: "After the user stops a turn, the next take reaches the conversation and its reply is read",
    applies: (agent) => agent.interrupt !== undefined,
    async run(context) {
      const { instance, agent } = context
      const gate = mkdtempSync(join(agent.project, ".ks-stop-"))
      const started = join(gate, "started")
      try {
        if (agent.window) await lookAway(context)
        const first = instance.take(`tell ${agent.name} Use your shell tool to run this exact command, then reply with only the word late: touch ${started}; sleep 120`)
        check(first.ok && agent.owns(first.conversation), `the first take went to ${first.conversation}: ${show(first)}`)
        await until("the agent running the first take's command", async () => (existsSync(started) ? true : undefined), 90, 250)
        await agent.interrupt!()
        await agent.idle(60)
        const { result, said } = await deliverAndRead(context, "Reply with only the word thyme.")
        check(result.reply?.kind === "answer", `the take after a stopped turn reported ${result.reply?.kind ?? result.replyProblem}`)
        const outcome = await replyOutcome(context, said, result)
        check(outcome.read, `the reply after a stopped turn was not read: ${outcome.reason}`)
      } finally {
        rmSync(gate, { recursive: true, force: true })
      }
    },
  },
  {
    id: "L2",
    title: "Installing the connector again while a conversation is open keeps that conversation reachable once the app is back",
    async run(context) {
      const { instance, agent } = context
      await instance.quit()
      const again = instance.connector("install", agent.kind, agent.folder, agent.tool)
      await instance.launch()
      check(again.status === 0, `installing again failed: ${again.stdout}${again.stderr}`)
      await until("the conversation known by its name again", () => (instance.take(`check on ${agent.name}`).ok ? true : undefined), 60, 2000)
      await deliverAndRead(context, "Reply with only the word hazel.")
    },
  },
  {
    id: "C1",
    title: "A take while the agent's app cannot be reached is never reported sent, and nothing arrives later",
    applies: (agent) => agent.server !== undefined,
    async run(context) {
      const { instance, agent } = context
      const body = "Reply with only the word sage."
      const since = (await agent.messages()).length
      await agent.server!.stop()
      let result: TakeResult
      try {
        result = instance.take(`tell ${agent.name} ${body}`)
      } finally {
        await agent.server!.start()
      }
      check(!result!.ok || (result!.receiptKind !== "sent" && result!.receiptKind !== "sentWithDraft"), `a take to an unreachable app read as sent: ${show(result!)}`)
      await new Promise((resolve) => setTimeout(resolve, 5000))
      check(users((await agent.messages()).slice(since), body).length === 0, "the take arrived after the app came back")
    },
  },
]

export const removal: Exercise = {
  id: "L1",
  title: "Uninstalling the connector removes it and leaves the agent's other configuration",
  async run(context) {
    const { instance, agent } = context
    await instance.quit()
    const removed = instance.connector("uninstall", agent.kind, agent.folder, agent.tool)
    check(removed.status === 0, `uninstall failed: ${removed.stdout}${removed.stderr}`)
    const status = instance.connector("status", agent.kind, agent.folder, agent.tool)
    check(/notInstalled/.test(status.stdout), `after uninstall: ${status.stdout}`)
    const leftovers = agent.untouched?.() ?? []
    check(leftovers.length === 0, leftovers.join("; "))
  },
}
