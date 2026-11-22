import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { basename, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { type AgentDriver, type AppWindow, type Message, type Shown, removeScratch, scratch } from "./driver.ts"
import { freePort, run, sleep, until } from "./util.ts"

const windowPlugin = join(dirname(fileURLToPath(import.meta.url)), "..", "bb-window")
const model = process.env.BB_MODEL ?? "gpt-6-luna"

export function bbMessages(events: any[]): Message[] {
  const ordered = [...events].sort((a, b) => a.seq - b.seq)
  const turnOf = new Map<string, string>()
  for (const event of ordered) {
    if (event.type === "turn/input/accepted" && typeof event.data?.clientRequestId === "string" && typeof event.scope?.turnId === "string") {
      turnOf.set(event.data.clientRequestId, event.scope.turnId)
    }
  }
  const messages: Message[] = []
  for (const event of ordered) {
    if (event.type === "client/turn/requested") {
      const input: any[] = Array.isArray(event.data?.input) ? event.data.input : []
      const text = input.filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("\n")
      const from = event.data?.initiator
      messages.push({ role: "user", text, turn: turnOf.get(event.data?.requestId), ...(from && from !== "user" ? { mark: from } : {}) })
    } else if (event.type === "item/completed" && event.data?.item?.type === "agentMessage" && typeof event.data.item.text === "string" && event.data.item.text) {
      messages.push({ role: "agent", text: event.data.item.text, turn: event.scope?.turnId })
    } else if (event.type === "turn/completed") {
      messages.push({ role: "ended", text: "", turn: event.scope?.turnId })
    }
  }
  return messages
}

function scratchProcesses(root: string, app: string): number[] {
  const name = basename(root)
  const candidates = run("/bin/ps", ["-A", "-o", "pid=,command="]).stdout.split("\n")
    .filter((line) => line.includes(app)).map((line) => Number(line.trim().split(/\s+/)[0]))
  return candidates.filter((pid) => pid > 0 && pid !== process.pid && run("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]).stdout.includes(name))
}

export class BBDriver implements AgentDriver {
  readonly kind = "bb"
  readonly name: string
  readonly root: string
  readonly project: string
  readonly folder: string
  private thread: string | undefined
  private appPids: number[] = []
  private windowPluginId: string | undefined
  private projectId: string | undefined
  private machineId: string | undefined
  private ports: { server: number; daemon: number } | undefined
  private readonly source = process.env.BB_APP ?? "/Applications/bb.app"
  private readonly app: string

  constructor(name: string) {
    this.name = name
    const { root, project } = scratch(name)
    this.root = root
    this.project = project
    this.folder = join(root, "bb")
    this.app = join(root, "bb.app")
  }

  get tool() { return join(this.folder, "bin", "bb") }
  get conversation() { return this.thread ? `bb:${this.thread}` : undefined }

  owns(conversation: string | undefined) {
    return !!this.thread && !!conversation && conversation.includes(this.thread)
  }

  private bb(args: string[], timeout = 60) {
    const record = JSON.parse(readFileSync(join(this.folder, "bb-app-runtime.json"), "utf8"))
    const env = { HOME: process.env.HOME!, PATH: "/usr/bin:/bin", BB_TELEMETRY: "false", BB_DATA_DIR: this.folder, BB_SERVER_URL: record.serverUrl }
    const result = run(this.tool, args, { env, timeout })
    if (result.status !== 0) throw new Error(`bb ${args.join(" ")} failed: ${result.stdout}${result.stderr}`)
    return result.stdout
  }

  private json(args: string[], timeout = 60): any {
    return JSON.parse(this.bb([...args, "--json"], timeout))
  }

  async setUp() {
    mkdirSync(this.folder, { recursive: true })
    if (!existsSync(this.source)) throw new Error(`bb is not installed at ${this.source} (or set BB_APP)`)
    const cloned = run("/bin/cp", ["-c", "-R", this.source, this.app], { timeout: 120 })
    if (cloned.status !== 0) throw new Error(`could not copy ${this.source}: ${cloned.stderr}`)
    const codexLogin = join(process.env.CODEX_AUTH_HOME ?? join(process.env.HOME!, ".codex"), "auth.json")
    if (!existsSync(codexLogin)) throw new Error(`no Codex login at ${codexLogin}: bb's threads run on Codex (or set CODEX_AUTH_HOME)`)
    mkdirSync(join(this.root, "codex-home"), { recursive: true })
    cpSync(codexLogin, join(this.root, "codex-home", "auth.json"))
    this.ports = { server: await freePort(), daemon: await freePort() }
    await this.launch()
    this.bb(["settings", "general", "onboardingCompletedAt", new Date().toISOString()])
    const helper = join(this.root, "bb-window")
    cpSync(windowPlugin, helper, { recursive: true, filter: (source) => !source.includes("/dist") && !source.includes("/node_modules") })
    this.json(["plugin", "install", helper, "--yes"], 300)
    const listed: any[] = this.json(["plugin", "list"])
    const entries = Array.isArray(listed) ? listed : (listed as any)?.plugins ?? []
    this.windowPluginId = entries.find((entry: any) => JSON.stringify(entry).includes("bb-window") || entry?.name === "KeyScribe conformance window")?.id
    if (!this.windowPluginId) throw new Error(`the conformance window plugin did not install: ${JSON.stringify(listed)}`)
  }

  private async launch() {
    rmSync(join(this.folder, "bb-app-runtime.json"), { force: true })
    run("/usr/bin/open", ["-n", "-g", "-a", this.app, "--env", `BB_DATA_DIR=${this.folder}`, "--env", `BB_SERVER_PORT=${this.ports!.server}`,
      "--env", `BB_HOST_DAEMON_PORT=${this.ports!.daemon}`, "--env", `PI_CODING_AGENT_DIR=${join(this.root, "pi-agent")}`, "--env", `CODEX_HOME=${join(this.root, "codex-home")}`, "--args", `--user-data-dir=${join(this.root, "electron")}`])
    await until("the scratch bb's server", () => (existsSync(join(this.folder, "bb-app-runtime.json")) && existsSync(this.tool) ? true : undefined), 120)
    await until("the scratch bb's CLI", () => { try { this.bb(["thread", "count"]); return true } catch { return undefined } }, 60)
    this.appPids = scratchProcesses(this.root, this.app)
  }

  private async kill() {
    for (let round = 0, quiet = 0; round < 30 && quiet < 4; round++) {
      const left = [...new Set([...(round === 0 ? this.appPids : []), ...scratchProcesses(this.root, this.app)])]
      quiet = left.length ? 0 : quiet + 1
      for (const pid of left) { try { process.kill(pid, "SIGKILL") } catch {} }
      await sleep(500)
    }
  }

  readonly server = {
    stop: async () => {
      const record = JSON.parse(readFileSync(join(this.folder, "bb-app-runtime.json"), "utf8"))
      const port = new URL(record.serverUrl).port
      const serving = run("/usr/sbin/lsof", ["-t", `-iTCP:${port}`, "-sTCP:LISTEN"]).stdout.split("\n").filter(Boolean).map(Number)
      for (const pid of [record.pid, ...serving]) { try { process.kill(pid, "SIGKILL") } catch {} }
      await until("the scratch bb's server to stop", () => { try { this.bb(["thread", "count"], 10); return undefined } catch { return true } }, 30, 500)
    },
    start: async () => {
      await this.kill()
      await this.launch()
      await until("the scratch thread listed again", () => { try { this.bb(["thread", "show", this.thread!]); return true } catch { return undefined } }, 60, 1000)
    },
  }

  readonly window: AppWindow = {
    pids: () => this.appPids,
    show: async () => {
      const opened = this.json(["thread", "open", this.thread!])
      if (!(opened?.delivered > 0)) throw new Error(`no scratch bb window took the thread: ${JSON.stringify(opened)}`)
    },
    look: async () => this.look(),
    close: async () => {
      const input = join(this.root, "close.json")
      writeFileSync(input, JSON.stringify({ thread: this.thread }))
      this.json(["plugin", "rpc", "call", this.windowPluginId!, "close", "--input-file", input])
      await until("every scratch bb window closed", async () => ((await this.windows()).length === 0 ? true : undefined), 15, 1000)
        .catch(() => { throw new Error("a scratch bb window stayed open") })
    },
    fill: async (text) => {
      const shown = await this.look(text)
      if (!shown.draft?.includes(text)) throw new Error(`the thread's message box did not take the draft: ${JSON.stringify(shown)}`)
    },
  }

  private async windows(fill?: string): Promise<{ shown: string | null; focused: boolean; draft: string | null }[]> {
    const input = join(this.root, "look.json")
    writeFileSync(input, JSON.stringify({ thread: this.thread, ...(fill === undefined ? {} : { fill }) }))
    const answer = this.json(["plugin", "rpc", "call", this.windowPluginId!, "look", "--input-file", input])
    return (answer?.result ?? answer)?.windows ?? []
  }

  private async look(fill?: string): Promise<Shown> {
    const windows = await this.windows(fill)
    const ours = windows.filter((window) => window.shown === this.thread)
    const focused = ours.find((window) => window.focused)
    return { thread: ours.length > 0, focused: !!focused, draft: (focused ?? ours[0])?.draft ?? null }
  }

  async noteFromHost() {
    this.json(["thread", "spawn", "--prompt", "Use your shell tool to sleep 5 seconds, then reply with only the word done.",
      "--project", this.projectId!, "--machine", this.machineId!, "--environment", this.project, "--parent-thread", this.thread!, "--parent-notifications", "auto", "--title", "kestrel helper", "--model", model, "--reasoning-level", "low"])
  }

  async start() {
    this.machineId = await until("the scratch bb's machine", () => {
      const machines: any[] = this.json(["machine", "list"])
      return machines.find((machine) => machine?.status === "connected")?.id
    }, 60, 1000)
    const created = this.json(["project", "create", "--name", this.name, "--root", this.project, "--machine", this.machineId!])
    this.projectId = created?.id ?? created?.project?.id
    if (typeof this.projectId !== "string") throw new Error(`bb project create returned no id: ${JSON.stringify(created)}`)
    const spawned = this.json(["thread", "spawn", "--prompt", "Reply with only the word ready.", "--project", this.projectId, "--machine", this.machineId!, "--environment", this.project, "--title", this.name, "--model", model, "--reasoning-level", "low"])
    const id = spawned?.id ?? spawned?.thread?.id ?? spawned?.threadId
    if (typeof id !== "string") throw new Error(`bb thread spawn returned no id: ${JSON.stringify(spawned)}`)
    this.thread = id
    await this.idle(180)
  }

  async idle(seconds: number) {
    this.bb(["thread", "wait", this.thread!, "--status", "idle", "--timeout", `${seconds}s`], seconds + 10)
  }

  async messages(): Promise<Message[]> {
    return bbMessages(this.json(["thread", "log", this.thread!, "--all"], 60))
  }

  diagnostics() {
    return {
      "bb-runtime": () => {
        const path = join(this.folder, "bb-app-runtime.json")
        return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : { missing: path }
      },
    }
  }

  async stop(keep: boolean) {
    await this.kill()
    removeScratch(this.root, keep)
  }
}
