import { run, sleep } from "./util.ts"

export class Tmux {
  readonly socket: string

  constructor(socket: string) {
    this.socket = socket
  }

  private tmux(args: string[]) {
    return run("tmux", ["-L", this.socket, ...args])
  }

  start(cwd: string, command: string) {
    const started = this.tmux(["new-session", "-d", "-s", "agent", "-x", "200", "-y", "50", "-c", cwd, command])
    if (started.status !== 0) throw new Error(`tmux could not start: ${started.stderr}`)
  }

  screen(): string {
    return this.tmux(["capture-pane", "-p", "-t", "agent"]).stdout
  }

  keys(...keys: string[]) {
    this.tmux(["send-keys", "-t", "agent", ...keys])
  }

  async type(text: string) {
    this.tmux(["send-keys", "-t", "agent", "-l", text])
    await sleep(500)
    this.tmux(["send-keys", "-t", "agent", "Enter"])
  }

  kill() {
    this.tmux(["kill-server"])
  }
}
