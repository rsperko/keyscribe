import { existsSync, mkdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { type AgentDriver, type Message, removeScratch, scratch } from "./driver.ts"
import { freePort, run, sleep, texts, until } from "./util.ts"

export class BBDriver implements AgentDriver {
  readonly kind = "bb"
  readonly name: string
  readonly root: string
  readonly project: string
  readonly folder: string
  private thread: string | undefined
  private appPids: number[] = []

  constructor(name: string) {
    this.name = name
    const { root, project } = scratch(name)
    this.root = root
    this.project = project
    this.folder = join(root, "bb")
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
    const app = process.env.BB_APP ?? "/Applications/bb.app"
    if (!existsSync(app)) throw new Error(`bb is not installed at ${app} (or set BB_APP)`)
    const before = new Set(run("/usr/bin/pgrep", ["-f", app]).stdout.split("\n").filter(Boolean).map(Number))
    const port = await freePort()
    run("/usr/bin/open", ["-n", "-g", "-a", app, "--env", `BB_DATA_DIR=${this.folder}`, "--env", `BB_SERVER_PORT=${port}`])
    await until("the scratch bb's server", () => (existsSync(join(this.folder, "bb-app-runtime.json")) && existsSync(this.tool) ? true : undefined), 120)
    this.appPids = run("/usr/bin/pgrep", ["-f", app]).stdout.split("\n").filter(Boolean).map(Number).filter((pid) => !before.has(pid))
    await until("the scratch bb's CLI", () => { try { this.bb(["thread", "count"]); return true } catch { return undefined } }, 60)
  }

  async start() {
    const spawned = this.json(["thread", "spawn", "--prompt", "Reply with only the word ready.", "--environment", this.project, "--title", this.name])
    const id = spawned?.id ?? spawned?.thread?.id ?? spawned?.threadId
    if (typeof id !== "string") throw new Error(`bb thread spawn returned no id: ${JSON.stringify(spawned)}`)
    this.thread = id
    await this.idle(180)
  }

  async idle(seconds: number) {
    this.bb(["thread", "wait", this.thread!, "--status", "idle", "--timeout", `${seconds}s`], seconds + 10)
  }

  async messages(): Promise<Message[]> {
    const events: any[] = this.json(["thread", "log", this.thread!, "--all"], 60)
    const messages: Message[] = []
    let turn: string | undefined
    for (const event of events) {
      const type = String(event.type ?? "")
      if (!/message/i.test(type)) continue
      const text = texts(event.data?.content ?? event.data?.text ?? event.data?.message ?? event.data).join("\n")
      if (/user/i.test(type)) {
        turn = String(event.seq)
        messages.push({ role: "user", text, turn })
      } else if (/assistant|agent/i.test(type) && text) {
        messages.push({ role: "agent", text, turn })
      }
    }
    return messages
  }

  async stop(keep: boolean) {
    for (const pid of this.appPids) { try { process.kill(pid, "SIGTERM") } catch {} }
    await sleep(1000)
    removeScratch(this.root, keep)
  }
}
