import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { command, type Message } from "./driver.ts"
import { claudeCredential, claudeLoginSettings } from "./logins.ts"
import { TerminalAgent } from "./terminal.ts"
import { texts } from "./util.ts"

export function claudeMessages(transcript: string): Message[] {
  const messages: Message[] = []
  let turn: string | undefined
  for (const line of transcript.split("\n")) {
    let entry: any
    try { entry = JSON.parse(line) } catch { continue }
    if (entry.isSidechain || entry.isMeta) continue
    const content = entry.message?.content
    if (entry.type === "user") {
      const parts = typeof content === "string" ? [content] : (content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text)
      if (!parts.length) continue
      turn = entry.uuid
      messages.push({ role: "user", text: parts.join("\n"), turn })
    } else if (entry.type === "assistant") {
      const parts = (content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text)
      if (parts.length) messages.push({ role: "agent", text: texts(parts).join("\n"), turn })
    } else if (entry.type === "system" && entry.subtype === "turn_duration") {
      messages.push({ role: "ended", text: "", turn })
    }
  }
  return messages
}

export class ClaudeDriver extends TerminalAgent {
  readonly kind = "claude"
  readonly tool = command("claude", "CLAUDE_BIN")
  readonly folder: string
  protected ready = /\? for shortcuts|bypass permissions|accept edits|auto mode on|shift\+tab to cycle|^\s*[>❯]\s*$/m

  constructor(name: string) {
    super(name)
    this.folder = join(this.root, "claude")
    this.screens = [
      { when: /trust the files in this folder|Yes, proceed/i, keys: ["Enter"] },
      { when: /choose the text style|dark mode|light mode/i, keys: ["Enter"] },
      { when: /use this API key\?/i, keys: ["Up", "Enter"] },
      { when: /security notes|press enter to continue/i, keys: ["Enter"] },
    ]
  }

  async setUp() {
    const from = join(process.env.CLAUDE_LOGIN_HOME ?? join(homedir(), ".claude"), "settings.json")
    const login = claudeLoginSettings(existsSync(from) ? JSON.parse(readFileSync(from, "utf8")) : {})
    const credential = claudeCredential(login, process.env)
    if (!credential.usable) {
      throw new Error(`a scratch Claude Code folder has no login: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY, or give ${from} an apiKeyHelper (or set CLAUDE_LOGIN_HOME)`)
    }
    mkdirSync(this.folder, { recursive: true })
    const key = credential.apiKey
    writeFileSync(join(this.folder, ".claude.json"), JSON.stringify({
      hasCompletedOnboarding: true,
      projects: { [this.project]: { hasTrustDialogAccepted: true } },
      ...(key ? { customApiKeyResponses: { approved: [key.slice(-20)], rejected: [] } } : {}),
    }))
    writeFileSync(join(this.folder, "settings.json"), JSON.stringify({ ...login, model: process.env.CLAUDE_MODEL ?? "haiku" }))
  }

  protected launch() {
    return `env CLAUDE_CONFIG_DIR='${this.folder}' '${this.tool}'`
  }

  private transcript(): string | undefined {
    const projects = join(this.folder, "projects")
    if (!existsSync(projects)) return undefined
    for (const slug of readdirSync(projects)) {
      const file = readdirSync(join(projects, slug)).find((name) => name.endsWith(".jsonl"))
      if (file) return join(projects, slug, file)
    }
    return undefined
  }

  protected async find() {
    return this.transcript()?.split("/").at(-1)?.replace(/\.jsonl$/, "")
  }

  async messages(): Promise<Message[]> {
    const file = this.transcript()
    if (!file) return []
    return claudeMessages(readFileSync(file, "utf8"))
  }
}
