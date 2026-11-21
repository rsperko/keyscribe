import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { command, type Message } from "./driver.ts"
import { TerminalAgent } from "./terminal.ts"
import { run } from "./util.ts"

export function piMessages(entries: any[]): Message[] {
  const messages: Message[] = []
  let turn: string | undefined
  for (const entry of entries) {
    if (entry.type !== "message") continue
    const content = entry.message?.content
    const text = typeof content === "string" ? content : (Array.isArray(content) ? content : [])
      .filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n")
    if (entry.message?.role === "user") {
      turn = entry.id
      messages.push({ role: "user", text, turn })
    } else if (entry.message?.role === "assistant" && text) {
      messages.push({ role: "agent", text, turn })
    }
  }
  return messages
}

function sessionFiles(folder: string): string[] {
  if (!existsSync(folder)) return []
  return readdirSync(folder, { recursive: true, encoding: "utf8" })
    .filter((name) => name.endsWith(".jsonl"))
    .map((name) => join(folder, name))
}

abstract class PiFamily extends TerminalAgent {
  readonly folder: string
  protected ready = /\S/
  private file: string | undefined

  constructor(name: string) {
    super(name)
    this.folder = join(this.root, "agent")
  }

  protected abstract copyLogin(from: string): void
  protected abstract userFolder: string

  async setUp() {
    const from = process.env.PI_LOGIN_HOME ?? this.userFolder
    if (!existsSync(from)) throw new Error(`no ${this.kind} login at ${from}: log in first, or set PI_LOGIN_HOME`)
    mkdirSync(this.folder, { recursive: true })
    this.copyLogin(from)
  }

  protected launch() {
    return `env PI_CODING_AGENT_DIR='${this.folder}' '${this.tool}'`
  }

  protected async find() {
    for (const file of sessionFiles(join(this.folder, "sessions"))) {
      for (const line of readFileSync(file, "utf8").split("\n")) {
        let entry: any
        try { entry = JSON.parse(line) } catch { continue }
        if (entry.type === "session" && entry.cwd === this.project) {
          this.file = file
          return entry.id as string
        }
      }
    }
    return undefined
  }

  async messages(): Promise<Message[]> {
    if (!this.file || !statSync(this.file, { throwIfNoEntry: false })) return []
    const entries: any[] = []
    for (const line of readFileSync(this.file, "utf8").split("\n")) {
      let entry: any
      try { entry = JSON.parse(line) } catch { continue }
      entries.push(entry)
    }
    return piMessages(entries)
  }
}

export class PiDriver extends PiFamily {
  readonly kind = "pi"
  readonly tool = command("pi", "PI_BIN")
  protected userFolder = join(homedir(), ".pi", "agent")

  protected copyLogin(from: string) {
    for (const name of ["auth.json", "models.json"]) {
      if (existsSync(join(from, name))) copyFileSync(join(from, name), join(this.folder, name))
    }
    const settings = existsSync(join(from, "settings.json")) ? JSON.parse(readFileSync(join(from, "settings.json"), "utf8")) : {}
    const kept = Object.fromEntries(["defaultProvider", "defaultModel", "defaultThinkingLevel"].filter((key) => key in settings).map((key) => [key, settings[key]]))
    if (process.env.PI_MODEL) kept.defaultModel = process.env.PI_MODEL
    writeFileSync(join(this.folder, "settings.json"), JSON.stringify(kept))
  }
}

export class OmpDriver extends PiFamily {
  readonly kind = "omp"
  readonly tool = command("omp", "OMP_BIN")
  protected userFolder = join(homedir(), ".omp", "agent")

  protected copyLogin(from: string) {
    for (const name of ["config.yml", "models.yml"]) {
      if (existsSync(join(from, name))) copyFileSync(join(from, name), join(this.folder, name))
    }
    for (const database of ["agent.db", "models.db"]) {
      if (existsSync(join(from, database))) run("/usr/bin/sqlite3", [join(from, database), `.backup '${join(this.folder, database)}'`])
    }
  }
}
