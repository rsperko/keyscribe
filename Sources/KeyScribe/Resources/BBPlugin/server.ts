import type { BbPluginApi } from "@get-bb/plugin-sdk"
import { randomBytes } from "node:crypto"
import { watch } from "node:fs"
import { readFile } from "node:fs/promises"
import { request } from "node:http"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { keyscribe, type Exchange, type Response } from "./keyscribe.ts"

const pageSize = 200
const pageLimit = 10
const historyLimit = "8"
const responseLimit = 512 * 1024

export function configPaths(moduleURL: string): string[] {
  const here = dirname(fileURLToPath(moduleURL))
  return [join(here, "keyscribe.json"), join(dirname(here), "keyscribe.json")]
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
  bb.onDispose(() => plugin.stop())
}
