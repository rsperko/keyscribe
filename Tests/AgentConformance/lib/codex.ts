import { connect, type Socket } from "node:net"
import { randomBytes } from "node:crypto"
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { type AgentDriver, type Message, command, removeScratch, scratch } from "./driver.ts"
import { pidsListeningOn, sleep, texts, until } from "./util.ts"
import { Tmux } from "./tmux.ts"

class Daemon {
  private socket: Socket
  private buffer = Buffer.alloc(0)
  private upgraded = false
  private fragment = ""
  private next = 0
  private pending = new Map<number, (message: any) => void>()

  private constructor(path: string) {
    this.socket = connect(path)
  }

  static async open(path: string): Promise<Daemon> {
    const daemon = new Daemon(path)
    await new Promise<void>((resolve, reject) => {
      daemon.socket.once("error", reject)
      daemon.socket.once("connect", () => {
        daemon.socket.write(`GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ${randomBytes(16).toString("base64")}\r\n\r\n`)
      })
      daemon.socket.on("data", (chunk) => daemon.receive(chunk, resolve))
    })
    await daemon.call("initialize", { clientInfo: { name: "ks-conformance", title: "ks-conformance", version: "0" }, capabilities: { experimentalApi: true, requestAttestation: false } })
    daemon.send({ method: "initialized" })
    return daemon
  }

  call(method: string, params: unknown, seconds = 20): Promise<any> {
    const id = ++this.next
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} timed out`)) }, seconds * 1000)
      this.pending.set(id, (message) => {
        clearTimeout(timer)
        message.error ? reject(new Error(`${method}: ${JSON.stringify(message.error)}`)) : resolve(message.result)
      })
      this.send({ id, method, params })
    })
  }

  close() { this.socket.destroy() }

  private send(message: unknown) {
    const payload = Buffer.from(JSON.stringify(message))
    const mask = randomBytes(4)
    let header: Buffer
    if (payload.length < 126) header = Buffer.from([0x81, 0x80 | payload.length])
    else if (payload.length < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 0x80 | 126; header.writeUInt16BE(payload.length, 2) }
    else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(payload.length), 2) }
    const masked = Buffer.from(payload)
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4]
    this.socket.write(Buffer.concat([header, mask, masked]))
  }

  private receive(chunk: Buffer, opened: () => void) {
    this.buffer = Buffer.concat([this.buffer, chunk])
    if (!this.upgraded) {
      const end = this.buffer.indexOf("\r\n\r\n")
      if (end < 0) return
      this.upgraded = true
      this.buffer = this.buffer.subarray(end + 4)
      opened()
    }
    for (;;) {
      if (this.buffer.length < 2) return
      const op = this.buffer[0] & 0x0f
      const fin = this.buffer[0] & 0x80
      let length = this.buffer[1] & 0x7f
      let offset = 2
      if (length === 126) { if (this.buffer.length < 4) return; length = this.buffer.readUInt16BE(2); offset = 4 }
      else if (length === 127) { if (this.buffer.length < 10) return; length = Number(this.buffer.readBigUInt64BE(2)); offset = 10 }
      if (this.buffer.length < offset + length) return
      const payload = this.buffer.subarray(offset, offset + length)
      this.buffer = this.buffer.subarray(offset + length)
      if (op === 0x9 || op === 0x8) continue
      this.fragment += payload.toString()
      if (!fin) continue
      const text = this.fragment
      this.fragment = ""
      let message: any
      try { message = JSON.parse(text) } catch { continue }
      if (message.id !== undefined && !message.method && this.pending.has(message.id)) {
        this.pending.get(message.id)!(message)
        this.pending.delete(message.id)
      }
    }
  }
}

export class CodexDriver implements AgentDriver {
  readonly kind = "codex"
  readonly home: string
  readonly project: string
  readonly root: string
  readonly tool = command("codex", "CODEX_BIN")
  private readonly tmux: Tmux
  private daemon: Daemon | undefined
  private thread: string | undefined
  readonly name: string

  constructor(name: string) {
    this.name = name
    const { root, project } = scratch(name)
    this.root = root
    this.project = project
    this.home = join(root, "codex")
    mkdirSync(this.home)
    this.tmux = new Tmux(`ks-conf-${process.pid}`)
  }

  get folder() { return this.home }
  get socket() { return join(this.home, "app-server-control", "app-server-control.sock") }
  get conversation() { return this.thread ? `codex:${this.thread}` : undefined }

  owns(conversation: string | undefined) {
    return !!this.thread && !!conversation && conversation.includes(this.thread)
  }

  async setUp() {
    const auth = join(process.env.CODEX_AUTH_HOME ?? join(homedir(), ".codex"), "auth.json")
    if (!existsSync(auth)) throw new Error(`no Codex login at ${auth}: log in to Codex first, or set CODEX_AUTH_HOME`)
    copyFileSync(auth, join(this.home, "auth.json"))
    chmodSync(join(this.home, "auth.json"), 0o600)
    const model = process.env.CODEX_MODEL ?? "gpt-6-luna"
    writeFileSync(join(this.home, "config.toml"), [
      `model = "${model}"`,
      `model_reasoning_effort = "low"`,
      "",
      `[projects."${this.project}"]`,
      `trust_level = "trusted"`,
      "",
    ].join("\n"))
  }

  async start() {
    this.tmux.start(this.project, `env CODEX_HOME='${this.home}' '${this.tool}'`)
    await this.answerStartScreens()
    await until("Codex's app server", () => (existsSync(this.socket) ? true : undefined), 60)
    this.daemon = await Daemon.open(this.socket)
    await this.tmux.type("Reply with only the word ready.")
    this.thread = await until("the scratch thread on the app server", async () => {
      const loaded: string[] = (await this.daemon!.call("thread/loaded/list", {}))?.data ?? []
      if (loaded[0]) return loaded[0]
      const listed: any[] = (await this.daemon!.call("thread/list", {}))?.data ?? []
      return listed.find((thread) => thread?.cwd === this.project)?.id ?? listed[0]?.id
    }, 90, 500)
    await this.idle(120)
    await this.daemon.call("thread/name/set", { threadId: this.thread, name: this.name })
  }

  private async answerStartScreens() {
    const end = Date.now() + 60_000
    while (Date.now() < end) {
      const screen = this.tmux.screen()
      if (/update available/i.test(screen) && /skip/i.test(screen) && /enter continue|esc skip/i.test(screen)) {
        this.tmux.keys("Escape")
      } else if (/hooks need review/i.test(screen)) {
        const lines = screen.split("\n")
        const trust = lines.findIndex((line) => /trust all/i.test(line))
        const selected = lines.findIndex((line) => /^\s*›/.test(line))
        for (let step = selected; step >= 0 && step < trust; step++) this.tmux.keys("Down")
        this.tmux.keys("Enter")
      } else if (/ask codex to do anything|for shortcuts/i.test(screen)) {
        return
      }
      await sleep(1000)
    }
    throw new Error(`Codex never reached its prompt; last screen:\n${this.tmux.screen()}`)
  }

  async idle(seconds: number) {
    await until("the Codex turn to finish", async () => {
      const read = await this.daemon!.call("thread/read", { threadId: this.thread })
      const status = JSON.stringify(read?.thread?.status ?? read?.status ?? "")
      return /idle|notLoaded/i.test(status) && !/active|running|inProgress/i.test(status) ? true : undefined
    }, seconds, 500)
  }

  async messages(): Promise<Message[]> {
    const listed = await this.daemon!.call("thread/turns/list", { threadId: this.thread, itemsView: "full" })
    const turns: any[] = [...(listed?.data ?? [])].reverse()
    const messages: Message[] = []
    for (const turn of turns) {
      for (const item of turn.items ?? []) {
        if (item.type === "userMessage") messages.push({ role: "user", text: texts(item.content ?? item).join("\n"), turn: turn.id, mark: item.clientId })
        if (item.type === "agentMessage") messages.push({ role: "agent", text: typeof item.text === "string" ? item.text : texts(item).join("\n"), turn: turn.id })
      }
    }
    return messages
  }

  untouched() {
    const config = readFileSync(join(this.home, "config.toml"), "utf8")
    const problems: string[] = []
    if (!/model_reasoning_effort = "low"/.test(config)) problems.push("uninstall removed the user's own settings from config.toml")
    if (/keyscribe/i.test(config)) problems.push("config.toml still mentions the connector")
    return problems
  }

  async stop(keep: boolean) {
    this.daemon?.close()
    this.tmux.kill()
    for (const pid of pidsListeningOn(this.socket)) { try { process.kill(pid, "SIGTERM") } catch {} }
    await sleep(1000)
    removeScratch(this.root, keep)
  }
}
