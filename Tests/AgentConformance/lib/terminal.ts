import { type AgentDriver, type AppWindow, type Message, command, removeScratch, scratch, settled } from "./driver.ts"
import { promptText, Tmux } from "./tmux.ts"
import { run, sleep, until } from "./util.ts"

function terminal(script: string) {
  const answer = run("/usr/bin/osascript", ["-e", `tell application "Terminal"\n${script}\nend tell`], { timeout: 30 })
  if (answer.status !== 0) throw new Error(`Terminal could not be scripted: ${answer.stderr.trim()}`)
  return answer.stdout.trim()
}

export function terminalWindow(tmux: Tmux, title: string, takeBehindDraft: AppWindow["takeBehindDraft"]): AppWindow {
  let id: number | undefined
  let shows = 0
  const open = () => id !== undefined && terminal(`exists window id ${id}`) === "true"
  const window: AppWindow = {
    owns: (listed) => listed.app === "com.apple.Terminal" && listed.title.includes(title),
    reopens: false,
    takeBehindDraft,
    app: "com.apple.Terminal",
    focus: async () => {
      terminal(`set index of window id ${id} to 1\nactivate`)
    },
    show: async () => {
      if (open()) return
      const unique = `${title} #${++shows}`
      const quoted = (text: string) => text.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"")
      try {
        id = Number(terminal([
          `set opened to do script "${quoted(tmux.attachCommand())}"`,
          `set custom title of opened to "${quoted(unique)}"`,
          "set title displays custom title of opened to true",
          "repeat with candidate in windows",
          `if custom title of tab 1 of candidate is "${quoted(unique)}" then return id of candidate`,
          "end repeat",
        ].join("\n"))) || undefined
        if (id === undefined) throw new Error(`no Terminal window titled ${unique}`)
        await until("the Terminal window attached to the agent", () => (tmux.clients() ? true : undefined), 15, 250)
      } catch (error) {
        id = undefined
        tmux.detach()
        await sleep(500)
        try { terminal(`close (every window whose custom title of tab 1 is "${quoted(unique)}") saving no`) } catch {}
        throw error
      }
    },
    look: async () => {
      if (!open()) return { thread: false, focused: false, draft: null }
      const front = terminal("return (frontmost as text) & \",\" & (id of front window as text)")
      return { thread: true, focused: front === `true,${id}`, draft: promptText(tmux.cursorLine()) }
    },
    fill: async (text) => {
      tmux.draft(text)
      await until("the draft in the agent's prompt box", async () => ((await window.look()).draft?.includes(text) ? true : undefined), 10, 250)
    },
    close: async () => {
      try {
        if (!open()) return
        tmux.detach()
        await sleep(500)
        if (open()) terminal(`close window id ${id} saving no`)
      } finally {
        id = undefined
      }
    },
  }
  return window
}

export type Screen = { when: RegExp; keys: string[] }

export abstract class TerminalAgent implements AgentDriver {
  abstract readonly kind: string
  abstract readonly folder: string
  abstract readonly tool: string
  readonly name: string
  readonly root: string
  readonly project: string
  protected readonly tmux: Tmux
  protected screens: Screen[] = []
  protected abstract ready: RegExp
  protected session: string | undefined

  constructor(name: string) {
    this.name = name
    const { root, project } = scratch(name)
    this.root = root
    this.project = project
    this.tmux = new Tmux(`ks-conf-${process.pid}`, command("tmux", "TMUX_BIN"))
  }

  private shown: AppWindow | undefined

  get window(): AppWindow {
    return this.shown ??= terminalWindow(this.tmux, `ks-conf ${this.kind} ${this.name} ${process.pid}`, "kept")
  }

  abstract setUp(): Promise<void>
  protected abstract launch(): string
  protected abstract find(): Promise<string | undefined>
  abstract messages(): Promise<Message[]>

  get conversation() { return this.session ? `${this.kind}:${this.session}` : undefined }

  owns(conversation: string | undefined) {
    return !!this.session && !!conversation && conversation.includes(this.session)
  }

  async start() {
    this.tmux.start(this.project, this.launch())
    await this.answerScreens()
    const first = "Reply with only the word ready."
    await this.tmux.type(first)
    const end = Date.now() + 120_000
    for (let waited = 0; !this.session && Date.now() < end; waited++) {
      this.session = await this.find()
      if (this.session) break
      if (waited % 5 === 4 && promptText(this.tmux.cursorLine())?.includes(first)) this.tmux.keys("Enter")
      await sleep(1000)
    }
    if (!this.session) throw new Error(`${this.kind} recorded no conversation; last screen:\n${this.tmux.screen()}`)
    await this.idle(180)
  }

  async idle(seconds: number) {
    await settled(() => this.messages(), seconds)
  }

  private async answerScreens() {
    const end = Date.now() + 90_000
    let previous = ""
    while (Date.now() < end) {
      const screen = this.tmux.screen()
      const known = this.screens.find((candidate) => candidate.when.test(screen))
      if (known) this.tmux.keys(...known.keys)
      else if (this.ready.test(screen) && screen === previous) return
      previous = known ? "" : screen
      await sleep(1000)
    }
    throw new Error(`${this.kind} never reached its prompt; last screen:\n${this.tmux.screen()}`)
  }

  async interrupt() {
    this.tmux.keys("Escape")
  }

  diagnostics() {
    return { "tmux-screen": () => this.tmux.screen() }
  }

  async stop(keep: boolean) {
    await this.window.close().catch(() => {})
    await this.tmux.stop()
    removeScratch(this.root, keep)
  }
}
