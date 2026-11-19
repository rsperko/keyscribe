import type { BbPluginApi } from "@get-bb/plugin-sdk"
import { randomBytes } from "node:crypto"
import { watch } from "node:fs"
import { readFile } from "node:fs/promises"
import { request } from "node:http"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import {
  acceptedInEndedTurn, appNameOf, composeChannel, keyscribe, readAloudReply, rpcContract, type ComposeAnswer, type Composed, type Exchange, type Response, type WindowReport,
} from "./keyscribe.ts"

const pageSize = 200
const pageLimit = 10
const historyLimit = "8"
const turnRecord = ["client/turn/requested", "turn/started", "turn/input/accepted", "turn/completed"]
const turnRecordLimit = 100
const responseLimit = 512 * 1024
const startDeadline = 1000
const composeDeadline = 6000

const readAloudTool = "tell_me_when_done"

export function readAloudToolName(pluginId: string): string {
  return `${pluginId.replace(/[^A-Za-z0-9]+/g, "_")}_${readAloudTool}`
}

export async function interactionStatus(sdk: BbPluginApi["sdk"], threadId: string, interactionId: string): Promise<string | null> {
  const interaction: { status?: unknown } = await sdk.threads.interactions.get({ threadId, interactionId })
  return typeof interaction?.status === "string" ? interaction.status : null
}

export function configPaths(moduleURL: string): string[] {
  const here = dirname(fileURLToPath(moduleURL))
  return [join(here, "keyscribe.json"), join(dirname(here), "keyscribe.json")]
}

export { rpcContract }

export function composeRelay(publish: (channel: string, payload: unknown) => void, after: (ms: number, fn: () => void) => () => void) {
  const pending = new Map<string, { started: boolean; stop: () => void; settle: (answer: Composed | null) => void }>()
  return {
    compose: (window: string, thread: string | null, text: string) => new Promise<Composed | null>((resolve) => {
      const id = randomBytes(6).toString("hex")
      const settle = (answer: Composed | null) => {
        const join = pending.get(id)
        if (!join) return
        pending.delete(id)
        join.stop()
        resolve(answer)
      }
      pending.set(id, { started: false, stop: after(startDeadline, () => settle({ outcome: "empty" })), settle })
      publish(composeChannel, { id, window, thread, text })
    }),
    starting: (id: string): boolean => {
      const join = pending.get(id)
      if (!join || join.started) return false
      join.started = true
      join.stop()
      join.stop = after(composeDeadline, () => join.settle(null))
      return true
    },
    answered: ({ id, ...answer }: ComposeAnswer) => {
      const join = pending.get(id)
      if (join?.started) join.settle(answer as Composed)
    },
  }
}

export function labelsChanged(bb: BbPluginApi) {
  ;(bb.rpc as { experimental_invalidateAll?: () => void }).experimental_invalidateAll?.()
}

function said(input: unknown): string {
  if (!Array.isArray(input)) return ""
  return input.filter((item) => item && item.type === "text" && typeof item.text === "string").map((item) => item.text).join("\n")
}

function post(socketPath: string, path: string, body: string, token: string): Exchange {
  let cancel = () => {}
  const response = new Promise<Response>((resolve, reject) => {
    const req = request({
      socketPath, path, method: "POST",
      headers: { authorization: "Bearer " + token, "content-type": "application/json", "content-length": Buffer.byteLength(body), connection: "close" },
    }, (res) => {
      const chunks: Buffer[] = []
      let size = 0
      res.on("data", (chunk: Buffer) => {
        size += chunk.length
        if (size > responseLimit) return req.destroy(new Error("too large"))
        chunks.push(chunk)
      })
      res.on("end", () => {
        const status = res.statusCode || 0
        resolve({ status, ok: status >= 200 && status < 300, text: Buffer.concat(chunks).toString("utf8") })
      })
      res.on("error", reject)
    })
    req.on("error", reject)
    cancel = () => req.destroy(new Error("cancelled"))
    req.end(body)
  })
  return { response, cancel: () => cancel() }
}

export default async function plugin(bb: BbPluginApi) {
  const relay = composeRelay((channel, payload) => bb.realtime.publish(channel, payload), (ms, fn) => {
    const timer = setTimeout(fn, ms)
    timer.unref?.()
    return () => clearTimeout(timer)
  })
  const plugin = keyscribe({
    listThreads: async () => {
      const found: { id: string; status: string }[] = []
      for (let page = 0; page < pageLimit; page++) {
        const threads = await bb.sdk.threads.list({ limit: pageSize, offset: page * pageSize })
        found.push(...threads.map((thread) => ({ id: thread.id, status: thread.status })))
        if (threads.length < pageSize) break
      }
      return found
    },
    history: async (threadId) => (await bb.sdk.threads.promptHistory({ threadId, limit: historyLimit })).map((entry) => said(entry.input)),
    turnInputs: async (threadId, failed, since) =>
      acceptedInEndedTurn(await bb.sdk.threads.events.list({ threadId, types: turnRecord, order: "desc", limit: turnRecordLimit }), failed, since),
    interaction: (threadId, interactionId) => interactionStatus(bb.sdk, threadId, interactionId),
    on: (event, handler) => bb.events.on(event as any, handler as any),
    compose: relay.compose,
  }, {
    now: () => Date.now(),
    read: (path) => readFile(path, "utf8"),
    after: (ms, fn) => {
      const timer = setTimeout(fn, ms)
      timer.unref?.()
      return () => clearTimeout(timer)
    },
    random: () => randomBytes(6).toString("hex"),
    post,
    log: (message) => bb.log.info(message),
    needsConfiguration: (message) => bb.status.needsConfiguration(message),
    watch: (path, fn) => {
      try {
        const watcher = watch(path, { persistent: false }, () => fn())
        watcher.on("error", () => watcher.close())
        return () => watcher.close()
      } catch {
        return () => {}
      }
    },
    labelled: () => labelsChanged(bb),
  }, configPaths(import.meta.url))
  bb.rpc.register(rpcContract, {
    window: (report: WindowReport) => { plugin.window(report); return null },
    labels: ({ keys }: { keys: string[] }) => plugin.labels(keys),
    readAloud: async ({ thread, on }: { thread: string; on: boolean }) => ({ message: await plugin.command(thread, on) }),
    composing: ({ id }: { id: string }) => ({ go: relay.starting(id) }),
    composed: (answer: ComposeAnswer) => { relay.answered(answer); return null },
  })
  const app = appNameOf(await plugin.settings)
  const tool = readAloudToolName(bb.pluginId)
  bb.agents.registerTool({
    name: tool,
    description: `The user has ${app}, a voice app on this Mac. Call this only when the user explicitly asks ${app}, or asks to hear it out loud, ` +
      `to report when the current work is done. Call it once, then keep working. When this turn ends, ${app} reports your final reply. ` +
      `If the work is already finished, answer instead of calling it. Not for a plain "let me know".`,
    presentation: { label: { pending: `Asking ${app} to report when done`, completed: `Asked ${app} to report when done` } },
    parameters: { type: "object", properties: {}, additionalProperties: false },
    execute: async (_params: unknown, context: { threadId: string }) => readAloudReply(app, await plugin.readAloud(context.threadId)),
  })
  bb.agents.configure(() => ({ tools: [tool], skills: [] }))
  bb.onDispose(() => plugin.stop())
}
