import { spawn, type ChildProcess } from "node:child_process"
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { type AgentDriver, type AppWindow, type Message, command, removeScratch, scratch, settled } from "./driver.ts"
import { traceLimit } from "../../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts"
import { freePort, run, sleep, stopEach, until } from "./util.ts"
import { tail } from "./artifacts.ts"

function traceRecords(trace: string): any[] {
  return trace.split("\n").filter(Boolean).map((line) => {
    try { return JSON.parse(line) } catch { return {} }
  })
}

export function reportedPages(trace: string): Set<string> {
  return new Set(traceRecords(trace).flatMap((entry) => (entry.dir === "page->ext" && typeof entry.page === "string" ? [entry.page] : [])))
}

export function newPageReported(trace: string, known: Set<string>): boolean {
  if ([...reportedPages(trace)].some((page) => !known.has(page))) return true
  if (traceRecords(trace).length >= traceLimit) throw new Error(`the bridge trace reached its limit of ${traceLimit} records, so a new page's report cannot be seen`)
  return false
}

export class DevtoolsSession {
  private next = 0
  private readonly waiting = new Map<number, { resolve: (message: any) => void; reject: (error: Error) => void }>()

  private readonly socket: WebSocket

  private constructor(socket: WebSocket) {
    this.socket = socket
    socket.onmessage = (event) => {
      const message = JSON.parse(String(event.data))
      const waiter = this.waiting.get(message.id)
      if (!waiter) return
      this.waiting.delete(message.id)
      if (message.error) waiter.reject(new Error(`${message.error.message ?? "a debugging command failed"}`))
      else waiter.resolve(message)
    }
    socket.onclose = () => {
      for (const waiter of this.waiting.values()) waiter.reject(new Error("the page's debugging connection closed"))
      this.waiting.clear()
    }
  }

  static open(url: string) {
    const socket = new WebSocket(url)
    return new Promise<DevtoolsSession>((resolve, reject) => {
      const fail = (why: string) => { clearTimeout(timer); socket.close(); reject(new Error(why)) }
      const timer = setTimeout(() => fail("the page's debugging connection did not open within 10 s"), 10_000)
      socket.onopen = () => { clearTimeout(timer); resolve(new DevtoolsSession(socket)) }
      socket.onerror = () => fail("the page's debugging connection failed")
    })
  }

  static async ofPage(port: number, matches: (url: string) => boolean): Promise<DevtoolsSession | undefined> {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(5000) }).catch(() => null))?.json().catch(() => null) as any[] | null
    const target = targets?.find((candidate) => candidate.type === "page" && matches(String(candidate.url)))
    return target ? DevtoolsSession.open(target.webSocketDebuggerUrl) : undefined
  }

  async evaluate(expression: string): Promise<any> {
    return (await this.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result?.result?.value
  }

  send(method: string, params: object = {}): Promise<any> {
    if (this.socket.readyState !== WebSocket.OPEN) return Promise.reject(new Error(`the page's debugging connection is closed, so ${method} was not sent`))
    const id = ++this.next
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.waiting.delete(id); reject(new Error(`the page did not answer ${method} within 10 s`)) }, 10_000)
      this.waiting.set(id, { resolve: (message) => { clearTimeout(timer); resolve(message) }, reject: (error) => { clearTimeout(timer); reject(error) } })
      this.socket.send(JSON.stringify({ id, method, params }))
    })
  }

  close() { this.socket.close() }
}

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
  private get automatedProfile() { return join(this.root, "automated-chrome") }
  private get chromeBin() { return process.env.CHROME_BIN ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }

  private chromePids(profile = this.chromeProfile): number[] {
    return run("/usr/bin/pgrep", ["-f", "--", `--user-data-dir=${profile.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}( |$)`]).stdout.split("\n").filter(Boolean).map(Number)
  }

  private async closeChrome(profile: string) {
    for (const pid of this.chromePids(profile)) { try { process.kill(pid, "SIGTERM") } catch {} }
    const closed = await until("the scratch Chrome closed", () => (this.chromePids(profile).length === 0 ? true : undefined), 15, 250).catch(() => false)
    if (closed) return
    for (const pid of this.chromePids(profile)) { try { process.kill(pid, "SIGKILL") } catch {} }
    await until("the scratch Chrome killed", () => (this.chromePids(profile).length === 0 ? true : undefined), 5, 250)
  }

  private trace() { return existsSync(this.tracePath) ? readFileSync(this.tracePath, "utf8") : "" }

  private async page(expression: string): Promise<any> {
    if (this.debugPort === undefined) return undefined
    const session = await DevtoolsSession.ofPage(this.debugPort, (url) => url.startsWith(this.origin))
    if (!session) return undefined
    try {
      return await session.evaluate(expression)
    } finally {
      session.close()
    }
  }

  private composer() { return `document.querySelector('textarea[data-conversation="${this.id}"]')` }

  private chromeSeen = { at: 0, pids: [] as number[] }

  async launchChrome(conversation = this.id) {
    this.debugPort = await freePort()
    this.chromeSeen.at = 0
    const log = openSync(join(this.root, "chrome.log"), "a")
    try {
      spawn(this.chromeBin, [
        `--user-data-dir=${this.chromeProfile}`, `--remote-debugging-port=${this.debugPort}`,
        "--no-first-run", "--no-default-browser-check", `--app=${this.origin}/?conversation=${conversation}`,
      ], { stdio: ["ignore", log, log], detached: true }).unref()
    } finally {
      closeSync(log)
    }
    return this.debugPort
  }

  chromeRunning() {
    this.chromeSeen.at = 0
    return this.recentChromePids().length > 0
  }

  private recentChromePids() {
    if (Date.now() - this.chromeSeen.at > 1000) this.chromeSeen = { at: Date.now(), pids: this.chromePids() }
    return this.chromeSeen.pids
  }

  readonly window: AppWindow = {
    owns: (listed) => this.recentChromePids().includes(Number(listed.spec.split(":")[0])),
    reopens: false,
    takeBehindDraft: "sent",
    takeInFrontOfDraft: "joined",
    show: async () => {
      this.chromeSeen.at = 0
      if (!this.chromePids().length) {
        await this.launchChrome()
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
      await this.closeChrome(this.chromeProfile)
    },
    openAutomated: async (kind) => {
      const known = reportedPages(this.trace())
      const other = await this.otherConversation()
      const port = await freePort()
      const log = openSync(join(this.root, "automated-chrome.log"), "a")
      try {
        spawn(this.chromeBin, [
          `--user-data-dir=${this.automatedProfile}`, `--remote-debugging-port=${port}`, "--headless=new",
          ...(kind === "webdriver" ? ["--enable-automation"] : ["--disable-blink-features=AutomationControlled"]), "--no-first-run", "--no-default-browser-check", "about:blank",
        ], { stdio: ["ignore", log, log], detached: true }).unref()
      } finally {
        closeSync(log)
      }
      let session: DevtoolsSession | undefined
      const close = () => stopEach(async () => session?.close(), () => this.closeChrome(this.automatedProfile))
      try {
        session = await until("the automated Chrome's blank page", () => DevtoolsSession.ofPage(port, () => true).catch(() => undefined), 60, 500)
        await session.send("Emulation.setFocusEmulationEnabled", { enabled: true })
        if (kind === "webdriver") {
          const userAgent = await session.evaluate("navigator.userAgent")
          await session.send("Emulation.setUserAgentOverride", { userAgent: String(userAgent).replace("HeadlessChrome/", "Chrome/") })
        }
        await session.send("Page.addScriptToEvaluateOnNewDocument", { source: "sessionStorage.setItem('ultimate.detached', '1')" })
        await session.send("Page.navigate", { url: `${this.origin}/?conversation=${other}` })
        const box = `document.querySelector('textarea[data-conversation="${other}"]')`
        const shown = await until("the automated page showing another conversation while it claims focus", async () => {
          const seen = await session!.evaluate(`(() => { const box = ${box};
            return { box: !!box && box.getClientRects().length > 0, focused: document.visibilityState === "visible" && document.hasFocus(),
              webdriver: navigator.webdriver === true, headless: /HeadlessChrome\\//.test(navigator.userAgent),
              shows: !!document.querySelector('textarea[data-conversation="${this.id}"]') } })()`).catch(() => undefined)
          return seen?.box && seen.focused ? seen : undefined
        }, 90, 500)
        const signals = kind === "webdriver" ? shown.webdriver && !shown.headless : !shown.webdriver && shown.headless
        if (!signals) throw new Error(`the automated page does not show only the ${kind} signal: ${JSON.stringify(shown)}`)
        if (shown.shows) throw new Error(`the automated page also shows the conversation under test: ${JSON.stringify(shown)}`)
        await until("the automated page's report to the connector", () => (newPageReported(this.trace(), known) ? true : undefined), 90, 500)
        if (!(await this.window.look()).thread) throw new Error("opening the automated page changed the conversation the page on screen shows")
      } catch (error) {
        await close().catch((closing) => { throw new Error(`${(error as Error).message}; closing the automated Chrome also failed: ${(closing as Error).message}`) })
        throw error
      }
      return close
    },
  }

  private other: number | undefined

  private async otherConversation() {
    if (this.other === undefined) {
      const created = (await (await this.api("/api/conversations", { title: "automated page" })).json()) as { id: number }
      this.other = created.id
    }
    return this.other
  }

  diagnostics() {
    const tailText = (path: string, limit = 64 * 1024) => existsSync(path) ? tail(path, limit).toString("utf8") : ""
    return {
      "ultimate-log": () => tailText(join(this.root, "ultimate.log")),
      "chrome-log": () => tailText(join(this.root, "chrome.log"), 8192),
      "automated-chrome-log": () => tailText(join(this.root, "automated-chrome.log")),
      "bridge-trace": () => tailText(this.tracePath).trim().split("\n").filter(Boolean).slice(-200).map(line => {
        try { return JSON.parse(line) } catch { return line }
      }),
    }
  }

  async stop(keep: boolean) {
    await stopEach(() => this.window.close(), () => this.closeChrome(this.automatedProfile), () => this.halt())
    removeScratch(this.root, keep)
  }
}
