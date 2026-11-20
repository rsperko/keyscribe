import type { AgentDriver, Message } from "./lib/driver.ts"
import type { Instance, TakeResult } from "./lib/instance.ts"
import { sha256 } from "./lib/util.ts"

export type Context = { instance: Instance; agent: AgentDriver; replyWait: number }
export type Exercise = { id: string; title: string; run: (context: Context) => Promise<void> }

class Failed extends Error {}
const check = (condition: unknown, why: string) => { if (!condition) throw new Failed(why) }
const plain = (text: string) => text.replace(/[\u200B-\u200D\u2060\uFEFF]/g, "").trim()
const users = (messages: Message[], text: string) => messages.filter((message) => message.role === "user" && plain(message.text) === text)
const show = (result: TakeResult) => JSON.stringify(result)

async function deliverAndRead(context: Context, body: string) {
  const { instance, agent } = context
  const result = instance.take(`tell ${agent.name} ${body}`, { waitReply: context.replyWait })
  check(result.ok, `the take was not delivered: ${show(result)}`)
  check(result.receiptKind === "sent", `expected a sent receipt: ${show(result)}`)
  check(agent.owns(result.conversation), `delivered to ${result.conversation}, expected ${agent.conversation}`)
  await agent.idle(context.replyWait)
  return { result, messages: await agent.messages() }
}
export const exercises: Exercise[] = [
  {
    id: "D1",
    title: "An idle conversation gets the take once, as the user's message",
    async run(context) {
      const body = "Reply with only the word kiwi."
      const { messages } = await deliverAndRead(context, body)
      const sent = users(messages, body)
      check(sent.length === 1, `the agent recorded ${sent.length} user messages "${body}"`)
    },
  },
  {
    id: "R1",
    title: "The reply read for a take is the reply the agent gave to that take",
    async run(context) {
      const body = "Reply with only the word mango."
      const { result, messages } = await deliverAndRead(context, body)
      check(result.reply, `no reply was reported: ${result.replyProblem ?? show(result)}`)
      const asked = users(messages, body).at(-1)
      check(asked, "the agent has no record of the take")
      const answer = messages.filter((message) => message.role === "agent" && message.turn === asked!.turn).at(-1)
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
      const { messages } = await deliverAndRead(context, body)
      check(users(messages, body).length === 1, `the agent has no user message "${body}"; it may have run as a command`)
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
      check(users(second.messages, body).length === 2, `the agent recorded ${users(second.messages, body).length} messages "${body}"`)
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
