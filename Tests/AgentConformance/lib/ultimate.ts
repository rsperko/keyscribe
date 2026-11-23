import { spawn, type ChildProcess } from "node:child_process"
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { type AgentDriver, type AppWindow, type Message, command, removeScratch, scratch, settled } from "./driver.ts"
import { freePort, run, sleep, until } from "./util.ts"

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
    const parts = (role: string) => (Array.isArray(entry.model) ? entry.model : [entry.model])
      .filter((part: any) => part?.role === undefined || part.role === role)
    if (/user/i.test(kind) && entry.input) {
      turn = String(entry.id)
      messages.push({ role: "user", text: textOf(parts("user")), turn })
    } else if (/assistant/i.test(kind)) {
      const text = textOf(parts("assistant"))
      if (text) messages.push({ role: "agent", text, turn })
      const stop = parts("assistant").at(-1)?.stopReason
      if (stop && stop !== "toolUse") messages.push({ role: "ended", text: "", turn })
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
  private debugPort: number | undefined

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
  get addresses() { return this.id === undefined ? undefined : { said: `ultimate ${this.id}`, absent: `ultimate ${this.id + 9000}` } }

  owns(conversation: string | undefined) {
    return this.id !== undefined && !!conversation && conversation.startsWith(`ultimate:${this.id}@`)
  }

  get url() { return this.origin }
  get projectHome() { return this.home }
  get conversationId() { return this.id }
  get tracePath() { return join(this.root, "bridge-trace.jsonl") }

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
    await this.serve(port)
    const created = (await (await this.api("/api/conversations", { title: this.name })).json()) as { id: number }
    this.id = created.id
  }

  readonly server = {
    stop: async () => { await this.halt() },
    start: async () => { await this.serve(Number(new URL(this.origin).port)) },
  }

  private async halt() {
    if (!this.process?.pid) return
    try { process.kill(-this.process.pid, "SIGTERM") } catch {}
    await sleep(2000)
    try { process.kill(-this.process.pid, "SIGKILL") } catch {}
    this.process = undefined
  }

  private async serve(port: number) {
    const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("ULTIMATE_")))
    const log = openSync(join(this.root, "ultimate.log"), "a")
    try {
      this.process = spawn(this.tool, [this.project, "--port", String(port), "--no-open"], {
        env: { ...environment, ULTIMATE_USER_HOME: this.user, ULTIMATE_HOME: this.home, NO_COLOR: "1",
          KEYSCRIBE_ULTIMATE_TRACE: this.tracePath,
          ...(process.env.ULTIMATE_MODEL ? { ULTIMATE_MODEL: process.env.ULTIMATE_MODEL } : {}) },
        stdio: ["ignore", log, log],
        detached: true,
      })
    } finally {
      closeSync(log)
    }
    await until("Ultimate to serve", async () => ((await this.api("/api/models").catch(() => null))?.ok ? true : undefined), 180, 1000)
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

  private get chromeProfile() { return join(this.root, "chrome") }

  private chromePids(): number[] {
    return run("/usr/bin/pgrep", ["-f", `--user-data-dir=${this.chromeProfile}`]).stdout.split("\n").filter(Boolean).map(Number)
  }

  private async page(expression: string): Promise<any> {
    if (this.debugPort === undefined) return undefined
    const targets = await (await fetch(`http://127.0.0.1:${this.debugPort}/json/list`, { signal: AbortSignal.timeout(5000) }).catch(() => null))?.json().catch(() => null) as any[] | null
    const target = targets?.find((candidate) => candidate.type === "page" && String(candidate.url).startsWith(this.origin))
    if (!target) return undefined
    const socket = new WebSocket(target.webSocketDebuggerUrl)
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const answer = await new Promise<any>((resolve, reject) => {
        timer = setTimeout(() => reject(new Error("the Ultimate page did not answer within 10 s")), 10_000)
        socket.onerror = () => reject(new Error("the Ultimate page's debugging connection failed"))
        socket.onclose = () => reject(new Error("the Ultimate page's debugging connection closed"))
        socket.onopen = () => socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true, awaitPromise: true } }))
        socket.onmessage = (event) => {
          const message = JSON.parse(String(event.data))
          if (message.id === 1) resolve(message)
        }
      })
      return answer.result?.result?.value
    } finally {
      clearTimeout(timer)
      socket.onclose = null
      socket.close()
    }
  }

  private composer() { return `document.querySelector('textarea[data-conversation="${this.id}"]')` }

  private chromeSeen = { at: 0, pids: [] as number[] }

  private recentChromePids() {
    if (Date.now() - this.chromeSeen.at > 1000) this.chromeSeen = { at: Date.now(), pids: this.chromePids() }
    return this.chromeSeen.pids
  }

  readonly window: AppWindow = {
    owns: (listed) => this.recentChromePids().includes(Number(listed.spec.split(":")[0])),
    reopens: false,
    takeBehindDraft: "kept",
    show: async () => {
      this.chromeSeen.at = 0
      if (!this.chromePids().length) {
        this.debugPort = await freePort()
        const log = openSync(join(this.root, "chrome.log"), "a")
        try {
          spawn(process.env.CHROME_BIN ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
            `--user-data-dir=${this.chromeProfile}`, `--remote-debugging-port=${this.debugPort}`,
            "--no-first-run", "--no-default-browser-check", `--app=${this.origin}/?conversation=${this.id}`,
          ], { stdio: ["ignore", log, log], detached: true }).unref()
        } finally {
          closeSync(log)
        }
      } else {
        await this.api("/api/ui", { set: { "shell.surface": "agent", "shell.conversation": this.id } })
      }
      await until("the conversation's message box in the Ultimate window", async () =>
        (await this.page(`(() => { const box = ${this.composer()}; return !!box && box.getClientRects().length > 0 })()`).catch(() => undefined)) ? true : undefined, 90, 500)
      this.chromeSeen.at = 0
    },
    look: async () => {
      const seen = await this.page(`(() => { const box = ${this.composer()}; return { thread: !!box && box.getClientRects().length > 0,
        focused: document.hasFocus() && document.visibilityState === "visible", draft: box ? box.value : null } })()`)
      .catch(() => undefined)
      if (!seen) return { thread: false, focused: false, draft: null }
      return { thread: seen.thread, focused: seen.thread && seen.focused, draft: seen.draft || null }
    },
    fill: async (text) => {
      await this.page(`(() => { const box = ${this.composer()}; box.focus();
        Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set.call(box, box.value + ${JSON.stringify(text)});
        box.dispatchEvent(new Event("input", { bubbles: true })) })()`)
      const shown = await this.window.look()
      if (!shown.draft?.includes(text)) throw new Error(`the conversation's message box did not take the draft: ${JSON.stringify(shown)}`)
    },
    close: async () => {
      this.chromeSeen.at = 0
      for (const pid of this.chromePids()) { try { process.kill(pid, "SIGTERM") } catch {} }
      const closed = await until("the scratch Chrome closed", () => (this.chromePids().length === 0 ? true : undefined), 15, 250).catch(() => false)
      if (closed) return
      for (const pid of this.chromePids()) { try { process.kill(pid, "SIGKILL") } catch {} }
      await until("the scratch Chrome killed", () => (this.chromePids().length === 0 ? true : undefined), 5, 250)
    },
  }

  diagnostics() {
    const tailText = (path: string, limit = 64 * 1024) => existsSync(path) ? readFileSync(path, "utf8").slice(-limit) : ""
    return {
      "ultimate-log": () => tailText(join(this.root, "ultimate.log")),
      "bridge-trace": () => tailText(this.tracePath).trim().split("\n").filter(Boolean).slice(-200).map(line => {
        try { return JSON.parse(line) } catch { return line }
      }),
    }
  }

  async stop(keep: boolean) {
    await this.window.close().catch(() => {})
    await this.halt()
    removeScratch(this.root, keep)
  }
}
