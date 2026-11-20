import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { command, type Message } from "./driver.ts"
import { TerminalAgent } from "./terminal.ts"
import { texts } from "./util.ts"

export class ClaudeDriver extends TerminalAgent {
  readonly kind = "claude"
  readonly tool = command("claude", "CLAUDE_BIN")
  readonly folder: string
  protected ready = /\? for shortcuts|bypass permissions|accept edits|^\s*>\s*$/m

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
    if (!process.env.ANTHROPIC_API_KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
      throw new Error("a scratch Claude Code folder has no login: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY")
    }
    mkdirSync(this.folder, { recursive: true })
    const key = process.env.ANTHROPIC_API_KEY
    writeFileSync(join(this.folder, ".claude.json"), JSON.stringify({
      hasCompletedOnboarding: true,
      projects: { [this.project]: { hasTrustDialogAccepted: true } },
      ...(key ? { customApiKeyResponses: { approved: [key.slice(-20)], rejected: [] } } : {}),
    }))
    writeFileSync(join(this.folder, "settings.json"), JSON.stringify({ model: process.env.CLAUDE_MODEL ?? "haiku" }))
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
    const messages: Message[] = []
    let turn: string | undefined
    for (const line of readFileSync(file, "utf8").split("\n")) {
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
      }
    }
    return messages
  }
}
