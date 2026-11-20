import { type AgentDriver, type Message, removeScratch, scratch, settled } from "./driver.ts"
import { Tmux } from "./tmux.ts"
import { sleep } from "./util.ts"

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
    this.tmux = new Tmux(`ks-conf-${process.pid}`)
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
    await this.tmux.type("Reply with only the word ready.")
    const end = Date.now() + 120_000
    while (!this.session && Date.now() < end) {
      this.session = await this.find()
      if (!this.session) await sleep(1000)
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

  async stop(keep: boolean) {
    this.tmux.kill()
    await sleep(500)
    removeScratch(this.root, keep)
  }
}
