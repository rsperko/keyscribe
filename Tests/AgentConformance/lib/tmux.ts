import { ensureExited, run, sleep } from "./util.ts"

export class Tmux {
  readonly socket: string
  readonly binary: string

  constructor(socket: string, binary = process.env.TMUX_BIN ?? "tmux") {
    this.socket = socket
    this.binary = binary
  }

  private tmux(args: string[]) {
    return run(this.binary, ["-L", this.socket, ...args])
  }

  start(cwd: string, command: string) {
    const started = this.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "agent", "-x", "200", "-y", "50", "-c", cwd, command])
    if (started.status !== 0) throw new Error(`tmux could not start: ${started.why}`)
  }

  screen(): string {
    return this.tmux(["capture-pane", "-p", "-t", "agent"]).stdout
  }

  cursorLine(): string {
    const row = this.tmux(["display-message", "-p", "-t", "agent", "#{cursor_y}"]).stdout.trim()
    if (!/^\d+$/.test(row)) return ""
    return this.screen().split("\n")[Number(row)] ?? ""
  }

  keys(...keys: string[]) {
    this.tmux(["send-keys", "-t", "agent", ...keys])
  }

  draft(text: string) {
    this.tmux(["send-keys", "-t", "agent", "-l", text])
  }

  async type(text: string) {
    this.draft(text)
    await sleep(500)
    this.tmux(["send-keys", "-t", "agent", "Enter"])
  }

  attachCommand() {
    return `exec '${this.binary}' -L '${this.socket}' attach -t agent`
  }

  clients() {
    return this.tmux(["list-clients"]).stdout.trim()
  }

  detach() {
    this.tmux(["detach-client", "-s", "agent"])
  }

  kill() {
    this.tmux(["kill-server"])
  }

  async stop(within = 10_000) {
    const panes = this.tmux(["list-panes", "-s", "-t", "agent", "-F", "#{pane_pid}"]).stdout.split("\n").map(Number).filter((pid) => pid > 0)
    this.kill()
    await ensureExited(panes.map((pid) => -pid), within, "the agent's processes")
  }
}

export function promptText(line: string): string | null {
  const text = line.replace(/^[\s│┃|>❯›»$%]+/, "").replace(/[\s│┃|]+$/, "")
  return text || null
}
