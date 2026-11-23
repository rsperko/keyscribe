import { existsSync } from "node:fs"
import { type AgentDriver, type AppWindow, type AwayWindow, type ListedWindow, type Message, command, removeScratch, scratch, settled } from "./driver.ts"
import { promptText, Tmux } from "./tmux.ts"
import { startingApp } from "./preflight.ts"
import { ensureExited, run, sleep, stopEach, until } from "./util.ts"

export type TerminalKind = "ghostty" | "terminal"

export function chooseTerminal(environment: NodeJS.ProcessEnv, exists: (path: string) => boolean = existsSync): TerminalKind {
  const asked = environment.AGENT_TERMINAL
  if (asked === "ghostty" || asked === "terminal") return asked
  if (asked) throw new Error(`AGENT_TERMINAL is ${asked}; it takes ghostty or terminal`)
  return exists(ghosttyApp(environment)) ? "ghostty" : "terminal"
}

export const ghosttyApp = (environment: NodeJS.ProcessEnv) => environment.GHOSTTY_APP ?? "/Applications/Ghostty.app"

type Opened = {
  readonly app: string
  owns(listed: ListedWindow): boolean
  alive(): boolean
  front(): boolean
  focus?(): Promise<void>
  close(): Promise<void>
}

type Host = {
  readonly app: string
  check(): void
  open(command: string, title: string): Promise<Opened>
}

function appleScript(script: string) {
  const answer = run("/usr/bin/osascript", ["-e", `tell application "Terminal"\n${script}\nend tell`], { timeout: 30 })
  if (answer.status !== 0) throw new Error(`Terminal could not be scripted: ${answer.why}`)
  return answer.stdout.trim()
}

const quoted = (text: string) => text.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"")

const appleTerminal: Host = {
  app: "com.apple.Terminal",
  check() {
    try {
      appleScript("count windows")
    } catch (error) {
      const from = startingApp() ?? "the terminal or app this run was started from"
      throw new Error(`the run shows each terminal agent in a Terminal window and could not drive Terminal (${(error as Error).message}). `
        + `Allow ${from} to control Terminal in System Settings > Privacy & Security > Automation, or set AGENT_TERMINAL=ghostty.`)
    }
  },
  async open(command, title) {
    let id: number | undefined
    try {
      id = Number(appleScript([
        `set opened to do script "${quoted(command)}"`,
        `set custom title of opened to "${quoted(title)}"`,
        "set title displays custom title of opened to true",
        "repeat with candidate in windows",
        `if custom title of tab 1 of candidate is "${quoted(title)}" then return id of candidate`,
        "end repeat",
      ].join("\n"))) || undefined
    } catch (error) {
      try { appleScript(`close (every window whose custom title of tab 1 is "${quoted(title)}") saving no`) } catch {}
      throw error
    }
    if (id === undefined) throw new Error(`no Terminal window titled ${title}`)
    const alive = () => appleScript(`exists window id ${id}`) === "true"
    return {
      app: this.app,
      owns: (listed) => listed.app === this.app && listed.title.includes(title),
      alive,
      front: () => appleScript("return (frontmost as text) & \",\" & (id of front window as text)") === `true,${id}`,
      focus: async () => { appleScript(`set index of window id ${id} to 1\nactivate`) },
      close: async () => { if (alive()) appleScript(`close window id ${id} saving no`) },
    }
  },
}

export const escaped = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

function frontPid() {
  const front = run("/usr/bin/lsappinfo", ["front"], { timeout: 5 }).stdout.trim()
  const info = front ? run("/usr/bin/lsappinfo", ["info", "-only", "pid", front], { timeout: 5 }).stdout : ""
  const pid = /\bpid"?\s*=\s*(\d+)/.exec(info)?.[1]
  return pid ? Number(pid) : undefined
}

const running = (pid: number) => run("/bin/kill", ["-0", String(pid)], { timeout: 5 }).status === 0

export function outside(environment: NodeJS.ProcessEnv) {
  const names = Object.keys(environment).filter((name) => /^(TMUX|HERDR_)\w*$/.test(name)).sort()
  return names.length ? `unset ${names.join(" ")}; ` : ""
}

function ghostty(environment: NodeJS.ProcessEnv): Host {
  const app = ghosttyApp(environment)
  return {
    app: "com.mitchellh.ghostty",
    check() {
      if (!existsSync(app)) throw new Error(`AGENT_TERMINAL is ghostty but there is no Ghostty at ${app} (set GHOSTTY_APP)`)
    },
    async open(command, title) {
      const opened = run("/usr/bin/open", ["-na", app, "--args", "--config-default-files=false", "--window-save-state=never", `--title=${title}`, "-e", "/bin/sh", "-c", outside(process.env) + command], { timeout: 30 })
      if (opened.status !== 0) throw new Error(`Ghostty did not open a window: ${opened.why}`)
      const launched = () => run("/usr/bin/pgrep", ["-f", "--", `--title=${escaped(title)}( |$)`], { timeout: 5 }).stdout.trim().split("\n").filter(Boolean).map(Number)
      const pid = await until(`the Ghostty window titled ${title}`, () => {
        const found = launched()
        return found.length === 1 ? found[0] : undefined
      }, 30, 250).catch(async (error) => {
        await ensureExited(launched(), 5_000, `Ghostty windows titled ${title}`)
        throw error
      })
      return {
        app: this.app,
        owns: (listed) => listed.spec.startsWith(`${pid}:`),
        alive: () => running(pid),
        front: () => frontPid() === pid,
        close: async () => {
          if (!running(pid)) return
          run("/bin/kill", [String(pid)], { timeout: 5 })
          await ensureExited([pid], 10_000, `the Ghostty window titled ${title}`)
        },
      }
    },
  }
}

export function terminalHost(environment: NodeJS.ProcessEnv = process.env): Host {
  return chooseTerminal(environment) === "ghostty" ? ghostty(environment) : appleTerminal
}

export function awayWindow(host: Host = terminalHost()): AwayWindow {
  let shown: Opened | undefined
  let shows = 0
  return {
    ...(host === appleTerminal ? { focus: async () => { await shown?.focus?.() } } : {}),
    show: async () => {
      if (shown?.alive()) return
      host.check()
      shown = await host.open("exec /bin/sleep 86400", `KeyScribe conformance, looking away ${process.pid} #${++shows}`)
    },
    owns: (listed) => !!shown && shown.owns(listed),
    close: async () => {
      await shown?.close()
      shown = undefined
    },
  }
}

export function terminalWindow(
  tmux: Tmux, title: string, takeBehindDraft: AppWindow["takeBehindDraft"], takeInFrontOfDraft: AppWindow["takeInFrontOfDraft"] = "joined",
  host: Host = terminalHost(),
): AppWindow {
  let opened: Opened | undefined
  let shows = 0
  const open = () => !!opened && opened.alive()
  const window: AppWindow = {
    owns: (listed) => !!opened && opened.owns(listed),
    reopens: false,
    takeBehindDraft,
    takeInFrontOfDraft,
    app: host.app,
    ...(host === appleTerminal ? { focus: async () => { await opened?.focus?.() } } : {}),
    show: async () => {
      if (open()) return
      host.check()
      const unique = `${title} #${++shows}`
      try {
        opened = await host.open(tmux.attachCommand(), unique)
        await until("the terminal window attached to the agent", () => (tmux.clients() ? true : undefined), 15, 250)
      } catch (error) {
        const failed = opened
        opened = undefined
        tmux.detach()
        await sleep(500)
        await failed?.close().catch((closing) => {
          throw new Error(`${(error as Error).message}; closing its window also failed: ${(closing as Error).message}`)
        })
        throw error
      }
    },
    look: async () => {
      if (!open()) return { thread: false, focused: false, draft: null }
      return { thread: true, focused: opened!.front(), draft: promptText(tmux.cursorLine()) }
    },
    fill: async (text) => {
      tmux.draft(text)
      await until("the draft in the agent's prompt box", async () => ((await window.look()).draft?.includes(text) ? true : undefined), 10, 250)
    },
    close: async () => {
      if (opened?.alive()) {
        tmux.detach()
        await sleep(500)
        await opened.close()
      }
      opened = undefined
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
    await stopEach(() => this.window.close(), () => this.tmux.stop())
    removeScratch(this.root, keep)
  }
}
