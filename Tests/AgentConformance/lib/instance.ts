import { spawn, type ChildProcess } from "node:child_process"
import { existsSync, mkdtempSync, openSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"
import { markKept, scratchPrefixes } from "./scratch.ts"
import { run, sleep, socketAnswers, until } from "./util.ts"

export type TakeResult = {
  id: string
  ok: boolean
  outcome?: string
  receipt?: string
  receiptKind?: string
  conversation?: string
  agent?: string
  request?: string
  reply?: { kind: string; length: number; sha256: string; ending?: string }
  replyProblem?: string
  hud?: string
  problem?: string
}

const requiredFlags = ["--no-input", "--connector", "--discovery-report", "--wait-reply", "--json", "--config-dir"]

export class Instance {
  readonly folder: string
  private process: ChildProcess | undefined

  readonly binary: string

  constructor(binary: string) {
    this.binary = binary
    this.folder = realpathSync(mkdtempSync(`/tmp/${scratchPrefixes.instance}`))
  }

  static locate(): string {
    const binary = resolve(process.env.KEYSCRIBE_APP ?? "KeyScribeDev.app/Contents/MacOS/KeyScribe")
    if (!existsSync(binary)) throw new Error(`no KeyScribe binary at ${binary}: build with make build, or set KEYSCRIBE_APP`)
    const help = run(binary, ["--help"]).stdout
    const missing = requiredFlags.filter((flag) => !help.includes(flag))
    if (missing.length) throw new Error(`${binary} predates ${missing.join(", ")}: rebuild it. Running it could start a second app on the real bridge.`)
    return binary
  }

  get bridge() { return join(this.folder, "agents", "bridge.sock") }

  cli(args: string[], timeout = 180) {
    return run(this.binary, ["--config-dir", this.folder, ...args], { timeout })
  }

  async prepare() {
    this.spawn()
    await until("settings.toml", () => (existsSync(join(this.folder, "settings.toml")) ? true : undefined), 60)
    await this.quit()
    const settings = join(this.folder, "settings.toml")
    const text = readFileSync(settings, "utf8")
    const enabled = /^\[features\]$/m.test(text)
      ? text.replace(/^\[features\]$/m, "[features]\nagents = true")
      : `${text.trimEnd()}\n\n[features]\nagents = true\n`
    const spoken = "[agents.spoken_result]\nenabled = true\ntext_only = true\n"
    const speaking = /\[agents\.spoken_result\]/.test(enabled)
      ? enabled.replace(/\[agents\.spoken_result\][\s\S]*?(?=\n\[|$)/, spoken)
      : `${enabled.trimEnd()}\n\n${spoken}`
    writeFileSync(settings, speaking)
  }

  windows(): { app: string; spec: string; title: string }[] {
    let app = "", pid = ""
    return this.cli(["--windows-probe"], 30).stdout.split("\n").flatMap((line) => {
      const owner = /^(\S+) pid=(\d+)/.exec(line)
      if (owner) { app = owner[1]; pid = owner[2] }
      const window = /AXStandardWindow id=(cg:\d+).*title=(.*)/.exec(line)
      return window ? [{ app, spec: `${pid}:${window[1]}`, title: window[2] }] : []
    })
  }

  focus(spec: string) {
    const result = this.cli(["--windows-probe", "--focus", spec], 15)
    if (result.status !== 0) throw new Error(`could not bring ${spec} forward: ${result.stdout}${result.stderr}`)
  }

  records(): any[] {
    const folder = join(this.folder, "history")
    if (!existsSync(folder)) return []
    return readdirSync(folder).filter((file) => file.endsWith(".jsonl"))
      .flatMap((file) => readFileSync(join(folder, file), "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)))
  }

  record(text: string): any {
    return this.records().filter((entry) => entry.heard === text || entry.heard?.endsWith(text)).at(-1)
  }

  private spawn() {
    const log = openSync(join(this.folder, "app.log"), "a")
    this.process = spawn(this.binary, ["--config-dir", this.folder, "--no-input"], { stdio: ["ignore", log, log], detached: true })
  }

  async launch() {
    this.spawn()
    await until("the test instance's bridge", async () => ((await socketAnswers(this.bridge)) ? true : undefined), 90)
    await until("the Agent mode", () => (existsSync(join(this.folder, "modes", "_agent.toml")) ? true : undefined), 30)
  }

  async quit() {
    const running = this.process
    this.process = undefined
    if (!running || running.exitCode !== null) return
    running.kill("SIGTERM")
    for (let waited = 0; waited < 50 && running.exitCode === null; waited++) await sleep(100)
    if (running.exitCode === null) running.kill("SIGKILL")
    await sleep(300)
  }

  connector(action: "install" | "uninstall" | "status", agent: string, folder: string, tool?: string) {
    return this.cli(["--connector", action, agent, "--folder", folder, ...(tool ? ["--tool", tool] : [])])
  }

  take(text: string, options: { waitReply?: number; mode?: string; timeout?: number } = {}): TakeResult {
    const args = ["--agent-take", text, "--json", "--timeout", String(options.timeout ?? 60)]
    if (options.waitReply) args.push("--wait-reply", String(options.waitReply))
    if (options.mode) args.push("--mode", options.mode)
    const { stdout, stderr } = this.cli(args, (options.timeout ?? 60) + (options.waitReply ?? 0) + 30)
    const line = stdout.trim().split("\n").reverse().find((candidate) => candidate.startsWith("{"))
    if (!line) throw new Error(`agent-take printed no result: ${stdout}${stderr}`)
    return JSON.parse(line) as TakeResult
  }

  async dispose(keep: boolean) {
    await this.quit()
    if (keep) markKept(this.folder)
    else rmSync(this.folder, { recursive: true, force: true })
  }
}
