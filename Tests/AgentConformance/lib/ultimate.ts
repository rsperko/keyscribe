import { spawn, type ChildProcess } from "node:child_process"
import { mkdirSync, openSync, realpathSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { type AgentDriver, type Message, command, removeScratch, scratch, settled } from "./driver.ts"
import { freePort, sleep, until } from "./util.ts"

type HistoryPage = { entries: any[]; before?: number }

export async function ultimateMessages(read: (before: number) => Promise<HistoryPage>): Promise<Message[]> {
  function textOf(value: any): string {
    if (typeof value === "string") return value
    if (Array.isArray(value)) return value.map(textOf).filter(Boolean).join("\n")
    if (value?.type === "text" && typeof value.text === "string") return value.text
    return value?.content === undefined ? "" : textOf(value.content)
  }
  let before = Number.MAX_SAFE_INTEGER
  const entries: any[] = []
  for (;;) {
    const page = await read(before)
    entries.push(...page.entries)
    if (page.before === undefined) break
    if (!Number.isSafeInteger(page.before) || page.before >= before || page.before < 1) throw new Error("invalid Ultimate history cursor")
    before = page.before
  }
  const messages: Message[] = []
  let turn: string | undefined
  for (const entry of entries.sort((a, b) => Number(a.id) - Number(b.id))) {
    const kind = String(entry.kind ?? "")
    const text = textOf(entry.model)
    if (/user/i.test(kind) && entry.input) {
      turn = String(entry.id)
      messages.push({ role: "user", text, turn })
    } else if (/assistant/i.test(kind) && text) {
      messages.push({ role: "agent", text, turn })
    }
  }
  return messages
}

export class UltimateDriver implements AgentDriver {
  readonly kind = "ultimate"
  readonly tool = command("ultimate", "ULTIMATE_BIN")
  readonly name: string
  readonly root: string
  readonly project: string
  readonly folder: string
  private readonly user: string
  private readonly home: string
  private process: ChildProcess | undefined
  private origin = ""
  private id: number | undefined

  constructor(name: string) {
    this.name = name
    const { root, project } = scratch(name)
    this.root = root
    this.project = project
    this.user = join(root, "user")
    this.folder = join(this.user, ".ultimate")
    this.home = join(this.folder, "projects", name)
  }

  get conversation() { return this.id === undefined ? undefined : `ultimate:${this.id}@${realpathSync(this.home)}` }

  owns(conversation: string | undefined) {
    return this.id !== undefined && !!conversation && conversation.startsWith(`ultimate:${this.id}@`)
  }

  get url() { return this.origin }
  get projectHome() { return this.home }
  get conversationId() { return this.id }

  api(path: string, payload?: object) {
    return fetch(this.origin + path, {
      method: payload ? "POST" : "GET",
      headers: { origin: this.origin, "content-type": "application/json", connection: "close" },
      signal: AbortSignal.timeout(30_000),
      ...(payload ? { body: JSON.stringify(payload) } : {}),
    })
  }

  async setUp() {
    mkdirSync(join(this.folder, "extensions"), { recursive: true })
    mkdirSync(this.home, { recursive: true })
    writeFileSync(join(this.folder, "onboarding.json"), JSON.stringify({ firstRunDone: true }))
    writeFileSync(join(this.folder, "settings.json"), JSON.stringify({ onboarding: false }))
  }

  async start() {
    const port = await freePort()
    this.origin = `http://127.0.0.1:${port}`
    const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("ULTIMATE_")))
    const log = openSync(join(this.root, "ultimate.log"), "a")
    this.process = spawn(this.tool, [this.project, "--port", String(port), "--no-open"], {
      env: { ...environment, ULTIMATE_USER_HOME: this.user, ULTIMATE_HOME: this.home, NO_COLOR: "1",
        ...(process.env.ULTIMATE_MODEL ? { ULTIMATE_MODEL: process.env.ULTIMATE_MODEL } : {}) },
      stdio: ["ignore", log, log],
      detached: true,
    })
    await until("Ultimate to serve", async () => ((await this.api("/api/models").catch(() => null))?.ok ? true : undefined), 180, 1000)
    const created = (await (await this.api("/api/conversations", { title: this.name })).json()) as { id: number }
    this.id = created.id
  }

  async idle(seconds: number) {
    await settled(() => this.messages(), seconds)
  }

  async messages(id = this.id): Promise<Message[]> {
    return ultimateMessages(async before => {
      const answer = await this.api(`/api/conversations/${id}/history?before=${before}`)
      if (!answer.ok) throw new Error(`Ultimate history answered ${answer.status}`)
      return await answer.json() as HistoryPage
    })
  }

  async stop(keep: boolean) {
    if (this.process?.pid) {
      try { process.kill(-this.process.pid, "SIGTERM") } catch {}
      await sleep(2000)
      try { process.kill(-this.process.pid, "SIGKILL") } catch {}
    }
    removeScratch(this.root, keep)
  }
}
