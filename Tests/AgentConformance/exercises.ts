import type { AgentDriver, Message } from "./lib/driver.ts"
import type { Instance, TakeResult } from "./lib/instance.ts"
import { spawn } from "node:child_process"
import { existsSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { sha256, until } from "./lib/util.ts"

export type Clipboard = { set(kind: "text" | "image", value?: string): void; keep<T>(work: () => Promise<T>): Promise<T> }
export type Context = { instance: Instance; agent: AgentDriver; replyWait: number; clipboard: Clipboard; holdSeconds?: number }
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

async function deliverAndRead(context: Context, body: string) {
  const { instance, agent } = context
  const since = (await agent.messages()).length
  const result = instance.take(`tell ${agent.name} ${body}`, { waitReply: context.replyWait })
  check(result.ok, `the take was not delivered: ${show(result)}`)
  check(result.receiptKind === "sent", `expected a sent receipt: ${show(result)}`)
  check(agent.owns(result.conversation), `delivered to ${result.conversation}, expected ${agent.conversation}`)
  await agent.idle(context.replyWait)
  const messages = await agent.messages()
  return { result, messages, since, fresh: messages.slice(since) }
}

const windowOf = (pids: number[], spec: string) => pids.includes(Number(spec.split(":")[0]))

async function bringForward(context: Context) {
  const { instance, agent } = context
  const window = agent.window!
  await window.show()
  const spec = await until("a window of the agent's app", () => instance.windows().find((w) => windowOf(window.pids(), w.spec))?.spec, 30, 500)
  instance.focus(spec)
  await until("the conversation in front", async () => ((await window.look()).focused ? true : undefined), 15, 500)
}

function lookAway(context: Context) {
  const { instance, agent } = context
  const other = instance.windows().find((w) => !windowOf(agent.window!.pids(), w.spec) && !w.app.startsWith("com.keyscribe."))
  check(other, "the run needs another app's window to move focus to")
  instance.focus(other!.spec)
}

function heardOrSaidWhyNot(context: Context, said: string) {
  const entry = context.instance.record(said)
  if (!entry) return undefined
  if (entry.spoken_reply?.text) return entry.spoken_reply.text as string
  return entry.steps?.find((step: any) => /^Not read aloud/.test(step.text))?.text as string | undefined
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
      const { instance, agent } = context
      for (const [said, body] of [
        [`tell ${agent.addresses!.said} Reply with only the word lime.`, "Reply with only the word lime."],
        [`tell ${agent.addresses!.said}, reply with only the word pear.`, "reply with only the word pear."],
      ]) {
        const since = (await agent.messages()).length
        const result = instance.take(said, { waitReply: context.replyWait })
        check(result.ok && agent.owns(result.conversation), `"${said}" went to ${result.conversation}: ${show(result)}`)
        await agent.idle(context.replyWait)
        check(users((await agent.messages()).slice(since), body).length === 1, `the agent has no user message "${body}"`)
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
      const { instance, agent } = context
      await bringForward(context)
      const body = "Reply with only the word quince."
      const since = (await agent.messages()).length
      const result = instance.take(body, { waitReply: context.replyWait })
      check(result.ok && agent.owns(result.conversation), `the take went to ${result.conversation}: ${show(result)}`)
      await agent.idle(context.replyWait)
      check(users((await agent.messages()).slice(since), body).length === 1, `the agent has no user message "${body}"`)
      const entry = await until("the take's History entry", () => instance.record(body), 15, 500)
      const chosen = entry.facts?.find((fact: any) => fact.label === "Chosen by")?.value
      check(chosen === "The conversation in front", `the take was chosen by ${chosen}`)
      await until("History saying the reply was not read because the conversation was in front",
        () => instance.record(body)?.steps?.some((step: any) => /was in front when it finished/.test(step.text)) ? true : undefined, 30, 500)
    },
  },
  {
    id: "D10",
    title: "A draft in the box of the conversation in front is sent with the take, and one in a box behind is left alone",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      const window = agent.window!
      await bringForward(context)
      const draft = "half a thought,"
      await window.fill(draft)
      lookAway(context)
      const behind = "Reply with only the word fig."
      const named = await deliverAndRead(context, behind)
      check(users(named.fresh, behind).length === 1, `the take behind was not sent alone as "${behind}"`)
      check((await window.look()).draft?.includes(draft), "the draft in the box behind was not left in place")
      await bringForward(context)
      const body = "reply with only the word olive."
      const since = (await agent.messages()).length
      const result = instance.take(body, { waitReply: context.replyWait })
      check(result.ok && agent.owns(result.conversation), `the take went to ${result.conversation}: ${show(result)}`)
      await agent.idle(context.replyWait)
      const joined = `${draft} ${body}`
      check(users((await agent.messages()).slice(since), joined).length === 1, `the agent has no user message "${joined}"`)
      check(!(await window.look()).draft, "the draft is still in the box after it was sent")
    },
  },
  {
    id: "N8",
    title: "Open brings the named conversation forward in its app",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      await bringForward(context)
      lookAway(context)
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
      const gate = mkdtempSync(join(tmpdir(), "ks-busy-"))
      const started = join(gate, "started")
      const release = join(gate, "release")
      const working = "Use your shell tool to run this exact command, then reply with only the word ready: "
        + `touch ${started}; i=0; while [ ! -f ${release} ] && [ $i -lt 900 ]; do sleep 0.2; i=$((i+1)); done`
      const later = "When the command finishes, reply with only the word cherry."
      try {
        if (agent.window) lookAway(context)
        const since = (await agent.messages()).length
        const first = instance.take(`tell ${agent.name} ${working}`)
        check(first.ok && agent.owns(first.conversation), `the first take went to ${first.conversation}: ${show(first)}`)
        await until("the agent running the first take's command", async () => (existsSync(started) ? true : undefined), 90, 250)
        spawn("/bin/sh", ["-c", `sleep ${context.holdSeconds ?? 15}; touch '${release}'`], { detached: true, stdio: "ignore" }).unref()
        const result = instance.take(`tell ${agent.name} ${later}`, { waitReply: context.replyWait + 30 })
        check(result.ok && agent.owns(result.conversation), `the take while busy went to ${result.conversation}: ${show(result)}`)
        await agent.idle(context.replyWait + 30)
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
      const { instance, agent } = context
      const body = "Reply with only the word lime."
      const since = (await agent.messages()).length
      const result = instance.take(`ask ${agent.name}, ${body}`, { waitReply: context.replyWait })
      check(result.ok && agent.owns(result.conversation), `ask went to ${result.conversation}: ${show(result)}`)
      await agent.idle(context.replyWait)
      check(users((await agent.messages()).slice(since), body).length === 1, `the agent has no user message "${body}"`)
    },
  },
  {
    id: "I1",
    title: "Copied text said as the clipboard's contents arrives as that text",
    async run(context) {
      const token = `clip${Date.now().toString(36)}`
      await context.clipboard.keep(async () => {
        context.clipboard.set("text", token)
        const { fresh } = await deliverAndRead(context, "Reply with only the word ready about insert clipboard contents.")
        check(fresh.some((message) => message.role === "user" && message.text.includes(token)), `the agent has no user message with the copied text ${token}`)
      })
    },
  },
  {
    id: "I2",
    title: "A copied image said as the clipboard's contents reaches the agent as a saved file's path",
    async run(context) {
      await context.clipboard.keep(async () => {
        context.clipboard.set("image")
        const { fresh } = await deliverAndRead(context, "Reply with only the word picture about insert clipboard contents.")
        check(fresh.some((message) => message.role === "user" && /\/[^\s]+\.png\b/.test(message.text)), "the agent has no user message with the image's path")
      })
    },
  },
  {
    id: "N10",
    title: "Open brings the conversation forward even when its app has no window open",
    applies: (agent) => agent.window !== undefined,
    async run(context) {
      const { instance, agent } = context
      await bringForward(context)
      await agent.window!.close()
      lookAway(context)
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
      const { agent, instance } = context
      if (agent.window) lookAway(context)
      for (let attempt = 1; ; attempt++) {
        const body = `Use your shell tool to run the command \`sleep 25\`, then reply with only the word apricot${attempt}.`
        await agent.noteFromHost!()
        const { result, fresh } = await deliverAndRead(context, body)
        const asked = fresh.find((message) => message.role === "user" && plain(message.text) === body)
        const noted = fresh.some((message) => message.mark && message.turn !== undefined && message.turn === asked?.turn)
        const answered = fresh.some((message) => message.role === "agent" && message.turn === asked?.turn)
        if (!noted || !answered || !result.reply) {
          check(attempt < 3, "the app's note never joined a dictated turn that the agent answered, so this run could not test it")
          continue
        }
        const read: string = await until("the reply read aloud", () => instance.record(body)?.spoken_reply?.text, 30, 500)
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
      if (context.agent.window) lookAway(context)
      await deliverAndRead(context, first)
      await deliverAndRead(context, second)
      for (const said of [first, second]) {
        await until(`the reply to "${said}" read aloud or the reason it was not`, () => heardOrSaidWhyNot(context, said), 60, 500)
      }
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
