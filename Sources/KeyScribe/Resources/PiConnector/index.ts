import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent"
import { readFile } from "node:fs/promises"
import { request as httpRequest } from "node:http"

const configPath: string | null = null
const loadedFrom: string | null = null

export type Response = { status: number; ok: boolean; text: string }
export type Exchange = { response: Promise<Response>; cancel: () => void }
export type Host = {
  pid: number
  now: () => number
  env: (name: string) => string | undefined
  read: (path: string) => Promise<string>
  after: (ms: number, fn: () => void) => () => void
  exec: (command: string, args: string[], timeoutMs: number) => Promise<{ code: number }>
  post: (socketPath: string, path: string, body: string, token: string) => Exchange
}
export type Settings = { configPath: string | null; loadedFrom: string | null }

type Config = {
  protocol: number
  socketPath: string
  tokenPath: string
  readyPath: string
  installation: string
  version?: string
  plugin?: string
  appName?: string
  environmentKeys?: string[]
}
type ReadAloud = boolean | "quiet" | null
type Ready = { launch: string; protocol: number }
type Pending = { id: string; generation: number; text: string; late: boolean; cancel: () => void }
type Item = {
  stale?: boolean
  kind: "hello" | "observe" | "reply"
  generation: number
  body: string
  session?: string | null
  connection?: string | null
  render?: () => string
  answer?: (text: string) => void
  done?: (outcome: Outcome) => void
}
type Outcome = "ok" | "late" | "unreachable" | "retired" | "rejected" | "stale" | false
type Command = {
  op: string
  id: string
  expectedSession?: string
  expectedPrompts?: number
  text?: string
  expiresAt?: number
}

const queueLimit = 64
const queueBytesLimit = 16 * 1024
const eventDeadline = 2000
const pollDeadline = 28000
const discoveryInterval = 10000
const admitLimit = 4096
const keystrokeQuiet = 3000
const keystrokeHoldLimit = 6000
const receiptDeadline = 3000
const lateLimit = 8
const staleCheck = 2000
const answerLimit = 8 * 1024
const waitingTitleLimit = 300
const waitingDetailLimit = 1000
const waitingSaidLimit = 500
const markAlphabet = ["\u200b", "\u200c", "\u200d", "\u2060"]
const nonceBytes = 5
const backoff = [30000, 60000, 120000, 300000]
const late = { late: true } as const
const unreachable = { unreachable: true } as const
const freshReasons = ["startup", "new", "fork"]
const features = ["focus", "label", "readiness", "notify"]
const readAloudTool = "tell_me_when_done"

export function readAloudToolName(plugin: string): string {
  return `${plugin.replace(/[^A-Za-z0-9]+/g, "_")}_${readAloudTool}`
}

export function connector(pi: ExtensionAPI, host: Host, settings: Settings): void {
  const instance = Math.random().toString(36).slice(2, 10)
  let config: Config | null = null
  let token = ""
  let session: string | null = null
  let freshSession: string | null = null
  let helloSession: string | null = null
  let generation = 0
  let currentTurn: string | null = null
  let turns = 0
  let prompts = 0
  let promptsOpen = 0
  let waiting: Waiting | null = null
  let said = ""
  const tools: { id: string; name: string; args: unknown }[] = []
  let lastKeyAt: number | null = null
  let lastInputSource: string | null = null
  const pending: Pending[] = []
  let lastAnswer = ""
  let lastFailed = false
  let staleWatch: (() => void) | null = null
  let idleChecks = 0
  const nonce = instanceNonce()
  let serial = 0
  let looping = false
  let ownedStatus = false
  let dormant = false
  let launch: string | null = null
  let refusedLaunch: string | null = null
  let failures = 0
  let cooldown: { cancel: () => void; over: Promise<void>; release: () => void } | null = null
  let greeting: { target: string; generation: number; result: Promise<boolean> } | null = null
  let nudge: (() => void) | null = null
  let connection: string | null = null
  const admitted = new Set<string>()
  let installation = settings.loadedFrom
  let retired = false
  let quiet = false
  let ctx: ExtensionContext | null = null
  let cwd = ""
  let stopKeys: (() => void) | null = null
  let polling: Exchange | null = null
  let offered = false

  const outbox: Item[] = []
  let outboxBytes = 0
  let wakeSender: (() => void) | null = null
  let wakeIdentity: (() => void) | null = null
  let hello: { target: string; generation: number; connection: string; result: Promise<boolean> } | null = null

  function statusKey(): string {
    return (config && config.plugin) || "voice"
  }

  async function loadConfig(): Promise<void> {
    if (!settings.configPath) throw new Error("no settings path")
    const loaded = JSON.parse(await host.read(settings.configPath)) as Config
    if (installation === null) installation = loaded.installation
    config = loaded
    if (loaded.installation !== installation) retire()
    if (!retired) offerReadAloud()
  }

  function terminalPlace(): Record<string, string> | undefined {
    const keys = (config && config.environmentKeys) || ["ZELLIJ_PANE_ID"]
    const place: Record<string, string> = {}
    for (const key of keys) {
      const value = host.env(key)
      if (value) place[key] = value
    }
    return Object.keys(place).length ? place : undefined
  }

  async function readiness(): Promise<Ready | null> {
    if (!config) return null
    try {
      const ready = JSON.parse(await host.read(config.readyPath))
      return ready && typeof ready.launch === "string" && ready.launch ? (ready as Ready) : null
    } catch (err) {
      return null
    }
  }

  function poke(): void {
    const resolve = nudge
    nudge = null
    if (resolve) resolve()
  }

  function rest(): Promise<void> {
    return new Promise((resolve) => {
      let cancel: (() => void) | null = null
      const done = () => {
        if (nudge === done) nudge = null
        if (cancel) cancel()
        resolve()
      }
      nudge = done
      if (dormant) return
      cancel = host.after(discoveryInterval, done)
      if (cooldown) cooldown.over.then(done)
    })
  }

  function goDormant(): void {
    dormant = true
    token = ""
    endCooldown()
  }

  function endCooldown(): void {
    if (!cooldown) return
    const ending = cooldown
    cooldown = null
    ending.cancel()
    ending.release()
  }

  function coolDown(): void {
    endCooldown()
    failures += 1
    const delay = backoff[Math.min(failures, backoff.length) - 1] * (1 + Math.random() / 4)
    let release: () => void = () => {}
    const over = new Promise<void>((resolve) => { release = resolve })
    const cancel = host.after(delay, () => {
      if (cooldown && cooldown.over === over) cooldown = null
      release()
    })
    cooldown = { cancel, over, release }
  }

  function open(path: string, body: string): Exchange | null {
    if (!config) return null
    try {
      return host.post(config.socketPath, path, body, token)
    } catch (err) {
      return null
    }
  }

  async function exchange(request: Exchange | null, ms: number): Promise<{ result: Response | typeof late | typeof unreachable; settled: Promise<void> }> {
    if (!request) return { result: unreachable, settled: Promise.resolve() }
    const settled = request.response.then(() => {}, () => {})
    let cancelTimer: () => void = () => {}
    const expired = new Promise<typeof late>((resolve) => { cancelTimer = host.after(ms, () => resolve(late)) })
    let result: Response | typeof late | typeof unreachable
    try {
      result = await Promise.race([request.response, expired])
    } catch (err) {
      result = unreachable
    } finally {
      cancelTimer()
    }
    if (result === late) request.cancel()
    return { result, settled }
  }

  function quietly(promise: Promise<unknown> | undefined | void): void {
    if (promise && typeof (promise as Promise<unknown>).catch === "function") (promise as Promise<unknown>).catch(() => {})
  }

  function settle(item: Item, ok: Outcome): void {
    if (item.done) item.done(ok)
  }

  function drain(keep: (item: Item) => boolean): void {
    for (const item of outbox.splice(0)) {
      if (keep(item)) {
        outbox.push(item)
      } else {
        outboxBytes -= item.body.length
        settle(item, false)
      }
    }
  }

  function enqueue(item: Item): void {
    if (outbox.length >= queueLimit || outboxBytes + item.body.length > queueBytesLimit) {
      settle(item, false)
      return lose()
    }
    outbox.push(item)
    outboxBytes += item.body.length
    const resolve = wakeSender
    wakeSender = null
    if (resolve) resolve()
  }

  function bound(event: Record<string, unknown>): string {
    return JSON.stringify({ ...event, instance, connection })
  }

  function observe(event: Record<string, unknown>): void {
    if (!session || helloSession !== session || quiet) return
    enqueue({ kind: "observe", session, generation, body: bound(event) })
  }

  function reply(gen: number, event: Record<string, unknown>): void {
    if (gen !== generation || !connection) return
    enqueue({ kind: "reply", generation: gen, connection, body: bound(event) })
  }

  function deliverable(item: Item): boolean {
    if (item.stale || item.generation !== generation) return false
    if (item.kind === "reply") return item.connection === connection
    if (item.session !== session) return false
    return item.kind === "hello" || helloSession === item.session
  }

  async function sender(): Promise<void> {
    for (;;) {
      while (outbox.length === 0) await new Promise<void>((resolve) => { wakeSender = resolve })
      const item = outbox.shift() as Item
      outboxBytes -= item.body.length
      if (!deliverable(item)) {
        settle(item, false)
        continue
      }
      const { result, settled } = await exchange(open("/event", item.render ? item.render() : item.body), eventDeadline)
      if (result === late) {
        settle(item, "late")
        if (item.kind !== "hello" && item.generation === generation) lose()
        await settled
        continue
      }
      const outcome: Outcome = result === unreachable ? "unreachable"
        : (result as Response).status === 403 ? "retired"
        : !(result as Response).ok ? "rejected"
        : deliverable(item) ? "ok" : "stale"
      if (outcome === "ok" && item.answer) item.answer((result as Response).text)
      settle(item, outcome)
      if (outcome !== "ok" && item.kind !== "hello" && item.generation === generation) lose()
    }
  }

  function greet(target: string): Promise<boolean> {
    if (greeting && greeting.target === target && greeting.generation === generation) return greeting.result
    const attempt = { target, generation, result: Promise.resolve(false) }
    attempt.result = tryHello(target).finally(() => {
      if (greeting === attempt) greeting = null
    })
    greeting = attempt
    return attempt.result
  }

  async function tryHello(target: string): Promise<boolean> {
    if (dormant || !config) return false
    const gen = generation
    const stillWanted = () => !dormant && gen === generation && target === session
    const ready = await readiness()
    if (!ready || !stillWanted() || !config) return false
    if (ready.protocol !== config.protocol) {
      goDormant()
      return false
    }
    if (ready.launch !== launch) {
      launch = ready.launch
      failures = 0
      token = ""
      endCooldown()
    }
    if (launch === refusedLaunch || cooldown) return false
    if (!token) {
      let read = ""
      try {
        read = (await host.read(config.tokenPath)).trim()
      } catch (err) {
        return false
      }
      if (!stillWanted() || ready.launch !== launch) return false
      token = read
    }
    return sayHello(target, launch as string)
  }

  function heard(outcome: Outcome, attemptLaunch: string): void {
    if (outcome === "ok") {
      failures = 0
      poke()
    } else if (outcome === "unreachable") {
      refusedLaunch = attemptLaunch
    } else if (outcome === "rejected") {
      goDormant()
    } else if (outcome === "late") {
      coolDown()
    }
  }

  function idle(): boolean {
    return currentTurn === null && !!ctx && ctx.isIdle()
  }

  function sayHello(target: string, attemptLaunch: string): Promise<boolean> {
    if (hello && hello.target === target && hello.generation === generation) return hello.result
    const attempt = { target, generation, connection: Math.random().toString(36).slice(2, 12), result: Promise.resolve(false) }
    const render = () => JSON.stringify(quiet ? {
      op: "hello", protocol: (config as Config).protocol, installation: (config as Config).installation,
      version: (config as Config).version, agent: "pi", agentVersion: "",
      instance, connection: attempt.connection, session: target, pid: host.pid, cwd, features, idle: idle(), gap: freshSession !== target,
    } : {
      op: "hello", protocol: (config as Config).protocol, installation: (config as Config).installation,
      version: (config as Config).version, agent: "pi", agentVersion: "",
      instance, connection: attempt.connection, session: target, pid: host.pid, cwd,
      features, title: pi.getSessionName() || undefined, prompts, waiting: waiting || undefined,
      idle: idle(), gap: freshSession !== target, turn: currentTurn || undefined,
      environment: terminalPlace(),
    })
    attempt.result = new Promise<boolean>((resolve) => {
      enqueue({
        kind: "hello", session: target, generation, render, body: render(),
        answer: (text) => { goQuiet(quietIn(text)) },
        done: (outcome) => {
          if (hello === attempt) hello = null
          if (outcome === "retired") retire()
          if (outcome === "ok") {
            helloSession = target
            connection = attempt.connection
            admitted.clear()
          }
          if (attempt.generation === generation && target === session && attemptLaunch === launch) heard(outcome, attemptLaunch)
          resolve(outcome === "ok")
        },
      })
    })
    hello = attempt
    return attempt.result
  }

  function clearOwnedUI(): void {
    if (ownedStatus) {
      ownedStatus = false
      if (ctx) ctx.ui.setStatus(statusKey(), undefined)
    }
  }

  function quietIn(text: string): boolean {
    try {
      return JSON.parse(text).quiet === true
    } catch (err) {
      return false
    }
  }

  function goQuiet(on: boolean): void {
    quiet = on
    if (!on) return
    drain((item) => item.kind !== "observe")
    clearOwnedUI()
  }

  function forget(): void {
    connection = null
    admitted.clear()
    for (const item of pending.splice(0)) item.cancel()
  }

  function cancelPoll(): void {
    const pending = polling
    polling = null
    if (pending) pending.cancel()
  }

  function lose(): void {
    generation += 1
    freshSession = null
    helloSession = null
    forget()
    drain(() => false)
    clearOwnedUI()
    if (config && session) quietly(greet(session))
  }

  function retire(): void {
    retired = true
    stopStaleWatch()
    goDormant()
    generation += 1
    freshSession = null
    helloSession = null
    forget()
    drain(() => false)
    clearOwnedUI()
    cancelPoll()
  }

  function leave(): void {
    generation += 1
    session = null
    freshSession = null
    helloSession = null
    forget()
    stopStaleWatch()
    currentTurn = null
    drain(() => false)
    clearOwnedUI()
    cancelPoll()
    if (stopKeys) stopKeys()
    stopKeys = null
    ctx = null
  }

  function adopt(id: string, reason: string, context: ExtensionContext): void {
    if (session) leave()
    ctx = context
    cwd = context.sessionManager.getCwd()
    session = id
    currentTurn = null
    prompts = 0
    promptsOpen = 0
    waiting = null
    said = ""
    tools.length = 0
    lastKeyAt = null
    if (freshReasons.includes(reason)) freshSession = id
    stopKeys = context.ui.onTerminalInput(() => { lastKeyAt = host.now(); return undefined })
    if (dormant && !retired) {
      dormant = false
      config = null
      launch = null
      failures = 0
    }
    if (config) quietly(greet(id))
    poke()
    const resolve = wakeIdentity
    wakeIdentity = null
    if (resolve) resolve()
  }

  function current(expected: string | undefined, gen: number): boolean {
    return gen === generation && expected === session
  }

  function refuse(gen: number, id: string, reason: string): void {
    reply(gen, { op: "refused", request: id, reason })
  }

  function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => { host.after(ms, resolve) })
  }

  async function submit(cmd: Command, gen: number): Promise<void> {
    const expected = cmd.expectedSession
    const hold = (): string | null => {
      if (!current(expected, gen)) return "sessionChanged"
      if (quiet) return "disconnected"
      if (!(host.now() < (cmd.expiresAt || 0))) return "expired"
      if (typeof cmd.expectedPrompts === "number" && cmd.expectedPrompts !== prompts) return "typedSince"
      if (!idle() || pending.some((item) => !item.late)) return "working"
      if (promptsOpen > 0) return "dialog"
      if (ctx && ctx.ui.getEditorText().trim()) return "draft"
      return null
    }
    const held = hold()
    if (held) return refuse(gen, cmd.id, held)
    const limit = host.now() + keystrokeHoldLimit
    while (lastKeyAt !== null && host.now() - lastKeyAt < keystrokeQuiet && host.now() < limit) {
      await sleep(Math.min(lastKeyAt + keystrokeQuiet, limit) - host.now())
      const again = hold()
      if (again) return refuse(gen, cmd.id, again)
    }
    serial += 1
    const text = (cmd.text || "") + nonce + mark(serial)
    const item: Pending = { id: cmd.id, generation: gen, text, late: false, cancel: () => {} }
    while (pending.length >= lateLimit) pending.shift()!.cancel()
    pending.push(item)
    try {
      pi.sendUserMessage(text, { deliverAs: "followUp" })
    } catch (err) {
      pending.splice(pending.indexOf(item), 1)
      return refuse(gen, cmd.id, String((err && (err as Error).message) || err).slice(0, 500))
    }
    item.cancel = host.after(receiptDeadline, () => { item.late = true })
  }

  function watchForStaleTurn(): void {
    stopStaleWatch()
    if (retired) return
    idleChecks = 0
    scheduleStaleCheck()
  }

  function scheduleStaleCheck(): void {
    staleWatch = host.after(staleCheck, () => {
      staleWatch = null
      if (currentTurn === null || !session) return
      idleChecks = ctx && ctx.isIdle() ? idleChecks + 1 : 0
      if (idleChecks >= 2) closeStaleTurn()
      else scheduleStaleCheck()
    })
  }

  function stopStaleWatch(): void {
    if (staleWatch) staleWatch()
    staleWatch = null
  }

  function closeStaleTurn(): void {
    stopStaleWatch()
    currentTurn = null
    lastAnswer = ""
    lastFailed = false
    if (session) observe({ op: "turnComplete", session, reason: "unknown" })
  }

  function received(message: unknown): void {
    if (lastInputSource !== "extension") return
    const text = messageText(message)
    const index = pending.findIndex((item) => item.text === text)
    if (index < 0) return
    const [item] = pending.splice(index, 1)
    item.cancel()
    reply(item.generation, { op: "submitted", request: item.id, turn: currentTurn || "" })
  }

  async function focus(cmd: Command, gen: number): Promise<void> {
    const surface = host.env("CMUX_SURFACE_ID")
    if (!surface) return refuse(gen, cmd.id, "notInCmux")
    if (!(host.now() < (cmd.expiresAt || 0))) return refuse(gen, cmd.id, "expired")
    if (!current(cmd.expectedSession, gen)) return refuse(gen, cmd.id, "sessionChanged")
    try {
      const result = await host.exec("cmux", ["focus-panel", "--panel", surface], 3000)
      if (result.code === 0) reply(gen, { op: "focused", request: cmd.id })
      else refuse(gen, cmd.id, "focusFailed")
    } catch (err) {
      refuse(gen, cmd.id, "focusFailed")
    }
  }

  async function handle(cmd: Command, gen: number): Promise<void> {
    const live = ctx ? ctx.sessionManager.getSessionId() : null
    if (!current(cmd.expectedSession, gen) || cmd.expectedSession !== live) return refuse(gen, cmd.id, "sessionChanged")
    if (cmd.op === "submit") return submit(cmd, gen)
    if (cmd.op === "focus") return focus(cmd, gen)
    if (cmd.op === "status") {
      ownedStatus = Boolean(cmd.text)
      if (ctx) ctx.ui.setStatus(statusKey(), cmd.text ? `${statusKey()}: ${cmd.text}` : undefined)
      return
    }
    refuse(gen, cmd.id, "unsupported")
  }

  async function pollLoop(): Promise<void> {
    for (;;) {
      if (dormant) {
        await rest()
        continue
      }
      if (!config) {
        try {
          await loadConfig()
        } catch (err) {
          config = null
          goDormant()
        }
        continue
      }
      if (!session) {
        await new Promise<void>((resolve) => { wakeIdentity = resolve })
        continue
      }
      const target = session
      const gen = generation
      if (target !== helloSession) {
        if (!(await greet(target)) && session === target && helloSession !== target) await rest()
        continue
      }
      polling = open("/poll", JSON.stringify({ session: target, instance, connection }))
      const { result, settled } = await exchange(polling, pollDeadline)
      polling = null
      if (result === late) {
        if (current(target, gen)) lose()
        await settled
        continue
      }
      if (!current(target, gen)) continue
      if (result === unreachable || !(result as Response).ok) {
        if (result !== unreachable && (result as Response).status !== 409) coolDown()
        lose()
        continue
      }
      let commands: Command[] = []
      try {
        commands = JSON.parse((result as Response).text)
      } catch (err) {
        lose()
        continue
      }
      for (const cmd of commands) {
        if (!current(target, gen)) break
        if (cmd.op === "retire") {
          retire()
          break
        }
        if (cmd.op === "quiet" || cmd.op === "admit") {
          reply(gen, { op: "ack", request: cmd.id })
          goQuiet(cmd.op === "quiet")
          if (cmd.op === "admit") {
            lose()
            break
          }
          continue
        }
        if (admitted.has(cmd.id)) {
          reply(gen, { op: "ack", request: cmd.id })
          continue
        }
        if (admitted.size >= admitLimit) {
          lose()
          break
        }
        admitted.add(cmd.id)
        reply(gen, { op: "ack", request: cmd.id })
        quietly(handle(cmd, gen))
      }
    }
  }

  function appName(): string {
    return (config && config.appName) || "the voice app"
  }

  function readAloudAnswer(text: string): ReadAloud {
    try {
      const answer = JSON.parse(text)
      return answer.quiet === true ? "quiet" : answer.spoken === true
    } catch (err) {
      return null
    }
  }

  function askToReadAloud(on: boolean): Promise<ReadAloud> {
    if (quiet) return Promise.resolve("quiet")
    if (!session || helloSession !== session || !connection) return Promise.resolve(null)
    const item: Item = { kind: "observe", session, generation, body: bound({ op: "notify", session, turn: currentTurn || "", on }) }
    return new Promise((resolve) => {
      const cancel = host.after(eventDeadline * 2, () => {
        item.stale = true
        resolve(null)
      })
      const finish = (answer: ReadAloud) => {
        cancel()
        resolve(answer)
      }
      item.answer = (text) => finish(readAloudAnswer(text))
      item.done = () => finish(null)
      enqueue(item)
    })
  }

  function toolAnswer(answer: ReadAloud): string {
    const app = appName()
    if (answer === true) return `${app} will read your final reply aloud when this turn ends. Say so in one short sentence and continue.`
    if (answer === false) return `Spoken replies are off in ${app}. Tell the user to turn on Read replies aloud in ${app}\u2019s Coding agent settings and ask again. Nothing will be read.`
    if (answer === "quiet") return `This conversation is disconnected from ${app}. Tell the user to reconnect it in ${app}\u2019s Coding agent settings. Nothing will be read.`
    return `${app} didn\u2019t confirm the request, so a spoken reply can\u2019t be promised. Tell the user.`
  }

  function commandAnswer(cancelling: boolean, answer: ReadAloud, running: boolean): string {
    const app = appName()
    if (answer === "quiet") return `This conversation is disconnected from ${app}. Reconnect it in ${app}\u2019s Coding agent settings.`
    if (answer === null) return cancelling ? `${app} didn\u2019t confirm the cancel.` : `${app} didn\u2019t confirm the request, so a spoken reply isn\u2019t certain.`
    if (cancelling) return `${app} won\u2019t read this reply aloud.`
    if (answer === false) return `Spoken replies are off. Turn on Read replies aloud in ${app}\u2019s Coding agent settings.`
    return running ? `${app} will read the result of this work aloud.` : `${app} will read your next reply aloud.`
  }

  function offerReadAloud(): void {
    if (offered || !config || !config.plugin) return
    offered = true
    const app = appName()
    const command = config.plugin
    pi.registerTool({
      name: readAloudToolName(command),
      label: `Tell me when done (${app})`,
      description: `The user has ${app}, a voice app on this Mac. Call this only when the user explicitly asks ${app}, or asks to hear it out loud, ` +
        `to report when the current work is done. Call it once, then keep working. When this turn ends, ${app} reads your final reply aloud. ` +
        `If the work is already finished, answer instead of calling it. Not for a plain "let me know".`,
      promptSnippet: `Have ${app} read your final reply aloud when the user asks for it`,
      parameters: { type: "object", properties: {}, additionalProperties: false } as any,
      async execute() {
        return { content: [{ type: "text", text: toolAnswer(await askToReadAloud(true)) }], details: undefined }
      },
    })
    pi.registerCommand(command, {
      description: `Have ${app} read the reply aloud when this work is done, or cancel that`,
      handler: async (args, context) => {
        const word = String(args || "").trim().toLowerCase()
        if (word && word !== "cancel") return context.ui.notify(`Use /${command} to hear the reply aloud, or /${command} cancel.`, "info")
        const running = currentTurn !== null
        context.ui.notify(commandAnswer(word === "cancel", await askToReadAloud(word !== "cancel"), running), "info")
      },
    })
  }

  pi.on("session_start", (event, context) => {
    if (context.mode !== "tui") return
    adopt(context.sessionManager.getSessionId(), event.reason, context)
    if (!looping) {
      looping = true
      quietly(sender())
      quietly(pollLoop())
    }
  })

  pi.on("session_shutdown", () => {
    if (session) leave()
  })

  pi.on("input", (event) => {
    if (!session) return
    lastInputSource = event.source
    if (event.source === "interactive") {
      if (currentTurn !== null && ctx && ctx.isIdle()) closeStaleTurn()
      prompts += 1
      observe({ op: "typed", session, prompts })
    }
  })

  pi.on("agent_start", () => {
    if (!session || currentTurn !== null) return
    lastAnswer = ""
    said = ""
    lastFailed = false
    turns += 1
    watchForStaleTurn()
    currentTurn = `${instance}.${turns}`
    observe({ op: "turnStarted", session, turn: currentTurn })
  })

  pi.on("agent_settled", (event) => {
    if (!session) return
    stopStaleWatch()
    currentTurn = null
    if (event.aborted) observe({ op: "turnComplete", session, reason: "aborted" })
    else if (lastFailed) observe({ op: "turnComplete", session, reason: "error" })
    else observe({ op: "turnComplete", session, reason: "complete", answer: boundedAnswer(lastAnswer) })
    lastAnswer = ""
    lastFailed = false
  })

  pi.on("message_end", (event) => {
    if (!session || !event.message || (event.message as { role?: string }).role !== "assistant") return
    const stop = (event.message as { stopReason?: string }).stopReason
    lastFailed = stop === "error" || stop === "aborted"
    lastAnswer = lastFailed ? "" : messageText(event.message)
    if (lastAnswer.trim()) said = lastAnswer.trim().slice(-waitingSaidLimit)
  })

  pi.on("message_start", (event) => {
    if (!session || !event.message || (event.message as { role?: string }).role !== "user") return
    received(event.message)
  })

  pi.on("session_info_changed", (event) => {
    if (!session) return
    observe({ op: "title", session, text: event.name || "" })
  })

  pi.on("tool_execution_start", (event) => {
    tools.push({ id: event.toolCallId, name: event.toolName, args: event.args })
  })

  pi.on("tool_execution_end", (event) => {
    const index = tools.findIndex((tool) => tool.id === event.toolCallId)
    if (index >= 0) tools.splice(index, 1)
  })

  pi.on("ui_prompt_start", (event) => {
    promptsOpen += 1
    if (promptsOpen > 1 || !session) return
    waiting = waitingFor(event.kind, event.title, tools[tools.length - 1], said)
    observe({ op: "waiting", session, waiting })
  })

  pi.on("ui_prompt_end", () => {
    if (promptsOpen === 0) return
    promptsOpen -= 1
    if (promptsOpen > 0 || !session) return
    waiting = null
    observe({ op: "waiting", session })
  })

}

type Waiting = { kind?: string; title?: string; tool?: string; detail?: string; said?: string }

function waitingFor(kind: string | undefined, title: string | undefined, tool: { name: string; args: unknown } | undefined, said: string): Waiting {
  const found: Waiting = {}
  if (kind) found.kind = kind
  if (title && title.trim()) found.title = title.trim().slice(0, waitingTitleLimit)
  if (tool) {
    found.tool = tool.name
    const detail = argumentText(tool.args)
    if (detail) found.detail = detail.slice(0, waitingDetailLimit)
  }
  if (said) found.said = said
  return found
}

function argumentText(args: unknown): string {
  if (args === undefined || args === null) return ""
  try {
    const text = typeof args === "string" ? args : JSON.stringify(args)
    return text === "{}" ? "" : text || ""
  } catch {
    return ""
  }
}

function instanceNonce(): string {
  const bytes = new Uint8Array(nonceBytes)
  globalThis.crypto.getRandomValues(bytes)
  let digits = ""
  for (const byte of bytes) {
    for (let shift = 6; shift >= 0; shift -= 2) digits += markAlphabet[(byte >> shift) & 3]
  }
  return digits
}

function mark(serial: number): string {
  let digits = ""
  for (let value = serial; value > 0; value = Math.floor(value / markAlphabet.length)) {
    digits = markAlphabet[value % markAlphabet.length] + digits
  }
  return digits
}

function boundedAnswer(text: string): string {
  const gap = "\n[…]\n"
  let budget = answerLimit
  let cut = text
  while (JSON.stringify(cut).length > answerLimit) {
    budget = Math.floor(budget * 0.75)
    const head = Math.floor(budget / 3)
    cut = text.slice(0, head) + gap + text.slice(text.length - Math.max(0, budget - head - gap.length))
  }
  return cut
}

function messageText(message: unknown): string {
  const content = (message as { content?: unknown }).content
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .filter((part) => part && typeof part === "object" && (part as { type?: string }).type === "text")
    .map((part) => String((part as { text?: unknown }).text ?? ""))
    .join("\n")
}

export function nodeHost(pi: ExtensionAPI): Host {
  return {
    pid: process.pid,
    now: () => Date.now(),
    env: (name) => process.env[name],
    read: (path) => readFile(path, "utf8"),
    after: (ms, fn) => {
      const timer = setTimeout(fn, ms)
      if (typeof timer.unref === "function") timer.unref()
      return () => clearTimeout(timer)
    },
    exec: async (command, args, timeoutMs) => {
      const result = await pi.exec(command, args, { timeout: timeoutMs })
      return { code: result.code }
    },
    post: (socketPath, path, body, token) => {
      let cancel: () => void = () => {}
      const response = new Promise<Response>((resolve, reject) => {
        const req = httpRequest({
          socketPath, path, method: "POST",
          headers: { authorization: "Bearer " + token, "content-type": "application/json", "content-length": Buffer.byteLength(body), connection: "close" },
        }, (res) => {
          const chunks: Buffer[] = []
          res.on("data", (chunk: Buffer) => chunks.push(chunk))
          res.on("end", () => {
            const status = res.statusCode || 0
            resolve({ status, ok: status >= 200 && status < 300, text: Buffer.concat(chunks).toString("utf8") })
          })
          res.on("error", reject)
        })
        req.on("error", reject)
        cancel = () => req.destroy(new Error("cancelled"))
        req.end(body)
      })
      return { response, cancel: () => cancel() }
    },
  }
}

export default function (pi: ExtensionAPI): void {
  connector(pi, nodeHost(pi), { configPath, loadedFrom })
}
