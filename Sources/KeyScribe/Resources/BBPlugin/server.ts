import type { BbPluginApi } from "@get-bb/plugin-sdk"
import { randomBytes } from "node:crypto"
import { watch } from "node:fs"
import { readFile } from "node:fs/promises"
import { request } from "node:http"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { keyscribe, readAloudReply, type Exchange, type Response, type WindowReport } from "./keyscribe.ts"

const pageSize = 200
const pageLimit = 10
const historyLimit = "8"
const responseLimit = 512 * 1024

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

type Checked<T> = { value: T } | { issues: { message: string }[] }
type Schema<T> = { readonly "~standard": { readonly version: 1; readonly vendor: string; readonly validate: (value: unknown) => Checked<T> } }

function schema<T>(accepts: (value: unknown) => value is T, message: string): Schema<T> {
  return { "~standard": { version: 1, vendor: "keyscribe", validate: (value) => accepts(value) ? { value } : { issues: [{ message }] } } }
}

function isWindowReport(value: unknown): value is WindowReport {
  if (!value || typeof value !== "object") return false
  const report = value as Record<string, unknown>
  return typeof report.window === "string" && report.window.length > 0 && report.window.length <= 64 && typeof report.focused === "boolean"
    && (report.thread === null || (typeof report.thread === "string" && report.thread.length <= 128))
}

export const rpcContract = {
  window: {
    input: schema(isWindowReport, "expected { window, focused, thread }"),
    output: schema((value): value is null => value === null, "expected null"),
  },
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
    interaction: (threadId, interactionId) => interactionStatus(bb.sdk, threadId, interactionId),
    on: (event, handler) => bb.events.on(event as any, handler as any),
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
  }, configPaths(import.meta.url))
  bb.rpc.register(rpcContract as never, { window: (report: WindowReport) => { plugin.window(report); return null } } as never)
  const app = (await plugin.settings)?.appName?.trim() || "the voice app"
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
