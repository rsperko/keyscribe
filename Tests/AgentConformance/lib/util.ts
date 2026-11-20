import { execFileSync, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { connect, createServer } from "node:net"

export const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export async function until<T>(what: string, find: () => T | undefined | Promise<T | undefined>, seconds: number, every = 250): Promise<T> {
  const end = Date.now() + seconds * 1000
  for (;;) {
    const found = await find()
    if (found !== undefined) return found
    if (Date.now() > end) throw new Error(`timed out after ${seconds} s waiting for ${what}`)
    await sleep(every)
  }
}

export function socketAnswers(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect(path)
    socket.once("connect", () => { socket.destroy(); resolve(true) })
    socket.once("error", () => resolve(false))
  })
}

export const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex")

export function run(command: string, args: string[], options: { env?: NodeJS.ProcessEnv; cwd?: string; timeout?: number } = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: (options.timeout ?? 60) * 1000, env: options.env ?? process.env, cwd: options.cwd })
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" }
}

export function pidsListeningOn(socket: string): number[] {
  try {
    return execFileSync("/usr/sbin/lsof", ["-t", socket], { encoding: "utf8" }).split("\n").filter(Boolean).map(Number)
  } catch {
    return []
  }
}

export function texts(value: unknown): string[] {
  if (typeof value === "string") return [value]
  if (Array.isArray(value)) return value.flatMap(texts)
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>
    if (typeof record.text === "string") return [record.text]
    return Object.values(record).flatMap(texts)
  }
  return []
}

export const freePort = () => new Promise<number>((resolve) => {
  const server = createServer()
  server.listen(0, () => {
    const port = (server.address() as { port: number }).port
    server.close(() => resolve(port))
  })
})
