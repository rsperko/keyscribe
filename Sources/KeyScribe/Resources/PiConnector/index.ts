import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent"
import { watch } from "node:fs"
import { readFile } from "node:fs/promises"
import { request as httpRequest } from "node:http"

const configPath: string | null = null
const loadedFrom: string | null = null
const installedFor: string | null = null
const builtVersion: string | null = null

export type Response = { status: number; ok: boolean; text: string }
export type Exchange = { response: Promise<Response>; cancel: () => void }
export type Host = {
  pid: number
  now: () => number
  env: (name: string) => string | undefined
  read: (path: string) => Promise<string>
  readBase64: (path: string) => Promise<string>
  after: (ms: number, fn: () => void) => () => void
  exec: (command: string, args: string[], timeoutMs: number) => Promise<{ code: number }>
  post: (socketPath: string, path: string, body: string, token: string) => Exchange
  watch?: (folder: string, changed: () => void, broken: () => void) => (() => void) | null
}
export type Settings = { configPath: string | null; loadedFrom: string | null; builtVersion?: string | null }

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
  focusDefinitions?: FocusDefinition[]
}
type FocusDefinition = { id: string; requiresEnv: string[]; argv: string[] }
type ReadAloud = boolean | "quiet" | null
type Ready = { launch: string; protocol: number }
type Pending = {
  id: string; generation: number; text: string; serial: number; late: boolean; cancel: () => void; prompt: string; steer: boolean
  putBack?: string
}
type Submission = {
  state: "holding" | "handed" | "seen" | "refused"; reason?: string; turn?: string; handedAt?: number; seenAt?: number; altered?: boolean; miss?: string
  withDraft?: boolean
}
type Receipt = { id: string; at: number; sending: boolean }
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
  images?: string[]
  merge?: boolean
  request?: string
  definition?: string
}

const queueLimit = 64
const queueBytesLimit = 16 * 1024
const eventDeadline = 2000
const pollDeadline = 310000
const discoveryInterval = 10000
const admitLimit = 4096
const keystrokeQuiet = 3000
const retitleDelay = 3000
const keystrokeHoldLimit = 6000
const receiptDeadline = 3000
const lateLimit = 8
const submissionLimit = 64
const receiptLimit = 16
const receiptKeep = 60000
const stallSlack = 1000
const stallRetries = 3
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
const features = ["focus", "focusDefinitions", "label", "readiness", "notify", "images", "check", "steer", "merge"]
const ompFeatures = ["focus", "focusDefinitions", "label", "readiness", "notify", "images", "check", "steer", "merge"]

const readAloudTool = "tell_me_when_done"

export function readAloudToolName(plugin: string): string {
  return `${plugin.replace(/[^A-Za-z0-9]+/g, "_")}_${readAloudTool}`
}

type Adapter = {
  agent: string
  version: () => string
  features: string[]
  title: () => string | undefined
  quiet: (context: ExtensionContext) => boolean
  idleDelivery?: "followUp"
  promptDelivery?: "aside"
  acceptsWhenSent: boolean
  retitle?: () => void
}

type Core = {
  start: (id: string, reason: string, context: ExtensionContext) => void
  end: () => void
  typed: () => void
  accepted: (text: string) => void
  turnStarted: () => void
  turnFinished: (aborted: boolean) => void
  cleared: () => void
  paused: (on: boolean) => void
  assistantEnded: (message: unknown) => void
  userStarted: (message: unknown) => void
  compacting: (on: boolean) => void
  titled: (text: string) => void
  toolStarted: (id: string, name: string, args: unknown) => void
  toolEnded: (id: string) => void
  waitBegan: (kind: string | undefined, title: string | undefined, holds: boolean, tool?: { id: string; name: string }) => void
  waitEnded: (holds: boolean) => void
}

function hostedByOmp(pi: ExtensionAPI): boolean {
  return (pi as unknown as { arktype?: unknown }).arktype !== undefined
}

function ompVersion(pi: ExtensionAPI): string {
  const own = (pi as unknown as { pi?: { VERSION?: unknown } }).pi
  return own && typeof own.VERSION === "string" ? own.VERSION : ""
}

function core(pi: ExtensionAPI, host: Host, settings: Settings, adapter: Adapter): Core {
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
  let holdsOpen = 0
  let compacting = false
  let waiting: Waiting | null = null
  let said = ""
  const tools: { id: string; name: string; args: unknown }[] = []
  let lastKeyAt: number | null = null
  const pending: Pending[] = []
  const steered: Pending[] = []
  const submissions = new Map<string, Submission>()
  const receipts: Receipt[] = []
  let lastAnswer = ""
  let lastPrompt: string | null = null
  let repliedThisRun = false
  let answered = false
  let lastFrom: "other" | null = null
  let lastFailed = false
  let staleWatch: (() => void) | null = null
  let titleCheck: (() => void) | null = null
  let idleChecks = 0
  const nonce = instanceNonce()
  let serial = 0
  let looping = false
  let ownedStatus = false
  let dormant = false
  let appAbsent = false
  let watchBroken = false
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
  let clears = 0

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
    const keys = (config && config.environmentKeys) || []
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
      appAbsent = !(ready && typeof ready.launch === "string" && ready.launch)
      return appAbsent ? null : (ready as Ready)
    } catch (err) {
      appAbsent = true
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
        const stop = cancel
        cancel = null
        if (stop) stop()
        resolve()
      }
      nudge = done
      if (dormant) return
      if (cooldown) cooldown.over.then(done)
      const folder = appAbsent && config && !watchBroken ? config.readyPath.slice(0, config.readyPath.lastIndexOf("/")) : null
      const unwatch = folder ? host.watch?.(folder, done, () => { watchBroken = true; done() }) ?? null : null
      if (unwatch) {
        cancel = unwatch
        void readiness().then((ready) => { if (ready) done() })
      } else {
        if (folder) watchBroken = true
        cancel = host.after(discoveryInterval, done)
      }
    })
  }

  function goDormant(): void {
    dormant = true
    token = ""
    endCooldown()
    if (titleCheck) titleCheck()
    titleCheck = null
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

  function deadline(ms: number, fn: () => void): () => void {
    let cancel: () => void = () => {}
    const arm = (stalls: number) => {
      const due = host.now() + ms
      cancel = host.after(ms, () => {
        if (host.now() - due >= stallSlack && stalls < stallRetries) arm(stalls + 1)
        else fn()
      })
    }
    arm(0)
    return () => cancel()
  }

  async function exchange(request: Exchange | null, ms: number): Promise<{ result: Response | typeof late | typeof unreachable; settled: Promise<void> }> {
    if (!request) return { result: unreachable, settled: Promise.resolve() }
    const settled = request.response.then(() => {}, () => {})
    let cancelTimer: () => void = () => {}
    const expired = new Promise<typeof late>((resolve) => { cancelTimer = deadline(ms, () => resolve(late)) })
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
      codeVersion: settings.builtVersion ?? undefined, agent: adapter.agent, agentVersion: adapter.version(),
      instance, connection: attempt.connection, session: target, pid: host.pid, cwd, features: adapter.features, idle: idle(), gap: freshSession !== target,
    } : {
      op: "hello", protocol: (config as Config).protocol, installation: (config as Config).installation,
      codeVersion: settings.builtVersion ?? undefined, agent: adapter.agent, agentVersion: adapter.version(),
      instance, connection: attempt.connection, session: target, pid: host.pid, cwd,
      features: adapter.features, title: adapter.title() || undefined, prompts, waiting: waiting || undefined,
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
            sendReceipts()
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
  }

  function dropSubmissions(): void {
    for (const item of pending.splice(0)) item.cancel()
    submissions.clear()
    receipts.length = 0
  }

  function track(id: string, change: Partial<Submission>): void {
    const was = submissions.get(id)
    submissions.delete(id)
    submissions.set(id, { ...(was || { state: "holding" }), ...change })
    for (const old of submissions.keys()) {
      if (submissions.size <= submissionLimit) break
      submissions.delete(old)
    }
  }

  function report(id: string): Record<string, unknown> {
    const sub = submissions.get(id)
    if (!sub) return { state: "unknown" }
    return { state: sub.state, reason: sub.reason, turn: sub.turn, handedAt: sub.handedAt, seenAt: sub.seenAt, altered: sub.altered, miss: sub.miss, withDraft: sub.withDraft }
  }

  function confirm(id: string): void {
    const at = host.now()
    receipts.push({ id, at, sending: false })
    while (receipts.length > receiptLimit) receipts.shift()
    sendReceipts()
  }

  function sendReceipts(): void {
    const now = host.now()
    for (let i = receipts.length - 1; i >= 0; i--) {
      if (now - receipts[i].at > receiptKeep) receipts.splice(i, 1)
    }
    if (!connection) return
    for (const receipt of receipts) {
      if (receipt.sending) continue
      const sub = submissions.get(receipt.id)
      receipt.sending = true
      enqueue({
        kind: "reply", generation, connection,
        body: bound({ op: "submitted", request: receipt.id, turn: (sub && sub.turn) || "", handedAt: sub && sub.handedAt, seenAt: sub && sub.seenAt, altered: sub && sub.altered, withDraft: sub && sub.withDraft }),
        done: (outcome) => {
          receipt.sending = false
          if (outcome !== "ok") return
          const index = receipts.indexOf(receipt)
          if (index >= 0) receipts.splice(index, 1)
        },
      })
    }
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
    dropSubmissions()
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
    dropSubmissions()
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
    holdsOpen = 0
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
    if (submissions.has(id)) track(id, { state: "refused", reason })
    reply(gen, { op: "refused", request: id, reason })
  }

  function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => { host.after(ms, resolve) })
  }

  async function images(paths: string[] | undefined): Promise<Array<{ type: "image"; data: string; mimeType: string }>> {
    const read = await Promise.all((paths || []).map(async (path) => {
      if (!path.toLowerCase().endsWith(".png")) return null
      try {
        return { type: "image" as const, data: await host.readBase64(path), mimeType: "image/png" }
      } catch {
        return null
      }
    }))
    return read.filter((image) => image !== null)
  }

  function runsAsCommand(text: string): boolean {
    return /^[/!]/.test(text.trimStart())
  }

  function joinable(cmd: Command): boolean {
    if (!cmd.merge || !ctx || ctx.mode !== "tui" || !ctx.model || compacting) return false
    return !runsAsCommand(ctx.ui.getEditorText()) && !runsAsCommand(cmd.text || "")
  }

  function putBack(draft: string): boolean {
    if (!draft.trim() || !ctx || ctx.ui.getEditorText()) return false
    ctx.ui.setEditorText(draft)
    return true
  }

  async function submit(cmd: Command, gen: number): Promise<void> {
    track(cmd.id, { state: "holding" })
    const expected = cmd.expectedSession
    const clearsAtStart = clears
    const hold = (): string | null => {
      if (!current(expected, gen) || clears !== clearsAtStart) return "sessionChanged"
      if (quiet) return "disconnected"
      if (!(host.now() < (cmd.expiresAt || 0))) return "expired"
      if (typeof cmd.expectedPrompts === "number" && cmd.expectedPrompts !== prompts) return "typedSince"
      if (pending.some((item) => !item.late)) return "working"
      if (holdsOpen > 0) return "dialog"
      if (ctx && ctx.ui.getEditorText().trim() && !joinable(cmd)) return "draft"
      return null
    }
    const attached = await images(cmd.images)
    const held = hold()
    if (held) return refuse(gen, cmd.id, held)
    const limit = host.now() + keystrokeHoldLimit
    while (lastKeyAt !== null && host.now() - lastKeyAt < keystrokeQuiet && host.now() < limit) {
      await sleep(Math.min(lastKeyAt + keystrokeQuiet, limit) - host.now())
      const again = hold()
      if (again) return refuse(gen, cmd.id, again)
    }
    serial += 1
    const draft = ctx && joinable(cmd) ? ctx.ui.getEditorText() : ""
    const joined = draft.trim() ? draft + (draft && !/\s$/.test(draft) ? " " : "") + (cmd.text || "") : cmd.text || ""
    const text = joined + nonce + mark(serial)
    const item: Pending = { id: cmd.id, generation: gen, text, serial, late: false, cancel: () => {}, prompt: promptDigest(cmd.text || ""), steer: false }
    while (pending.length >= lateLimit) pending.shift()!.cancel()
    pending.push(item)
    track(cmd.id, { state: "handed", handedAt: host.now(), withDraft: draft.trim() ? true : undefined })
    try {
      const deliverAs = idle() ? adapter.idleDelivery : promptsOpen > 0 && adapter.promptDelivery ? adapter.promptDelivery : "steer"
      item.steer = deliverAs === "steer" || deliverAs === "aside"
      if (draft.trim() && ctx) ctx.ui.setEditorText("")
      const sent: unknown = pi.sendUserMessage(attached.length ? [{ type: "text", text }, ...attached] : text, deliverAs ? { deliverAs } : {})
      if (sent && typeof (sent as Promise<void>).then === "function") {
        (sent as Promise<void>).then(() => {
          if (adapter.acceptsWhenSent && item.steer) accepted(text)
        }, (err: unknown) => {
          const index = pending.indexOf(item)
          if (index < 0) return
          pending.splice(index, 1)
          item.cancel()
          if (ctx && ctx.ui.getEditorText() === text) ctx.ui.setEditorText(draft)
          else putBack(draft)
          refuse(gen, cmd.id, String((err && (err as Error).message) || err).slice(0, 500))
        })
      }
    } catch (err) {
      pending.splice(pending.indexOf(item), 1)
      putBack(draft)
      return refuse(gen, cmd.id, String((err && (err as Error).message) || err).slice(0, 500))
    }
    item.cancel = host.after(receiptDeadline, () => {
      item.late = true
      if (pending.includes(item) && putBack(draft)) item.putBack = draft
    })
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
      idleChecks = ctx && adapter.quiet(ctx) ? idleChecks + 1 : 0
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

  function beginTurn(): void {
    if (!session || currentTurn !== null) return
    lastAnswer = ""
    said = ""
    lastFailed = false
    lastPrompt = null
    lastFrom = null
    repliedThisRun = false
    answered = false
    turns += 1
    watchForStaleTurn()
    currentTurn = `${instance}.${turns}`
    observe({ op: "turnStarted", session, turn: currentTurn })
  }

  function finishTurn(aborted: boolean): void {
    if (!session) return
    stopStaleWatch()
    currentTurn = null
    if (aborted) observe({ op: "turnComplete", session, reason: "aborted" })
    else if (lastFailed) observe({ op: "turnComplete", session, reason: "error" })
    else observe({ op: "turnComplete", session, reason: "complete", answer: boundedAnswer(lastAnswer), prompt: lastPrompt ?? undefined, from: lastFrom ?? undefined })
    lastAnswer = ""
    lastPrompt = null
    lastFrom = null
    lastFailed = false
    answered = false
  }

  function received(message: unknown): void {
    const text = messageText(message)
    const serialIn = markedSerial(text)
    const taken = serialIn === null ? -1 : steered.findIndex((item) => item.serial === serialIn)
    if (taken >= 0) {
      const [item] = steered.splice(taken, 1)
      lastPrompt = item.prompt
      if (session) observe({ op: "absorbed", session, turn: currentTurn || "", prompt: item.prompt, request: item.id })
      return
    }
    const item = take(text, serialIn)
    lastPrompt = item ? item.prompt : promptDigest(text)
    if (item) settleSeen(item, text, currentTurn || "")
  }

  function accepted(text: string): void {
    const item = take(text, markedSerial(text))
    if (!item || !item.steer) return
    steered.push(item)
    while (steered.length > lateLimit) steered.shift()
    settleSeen(item, text, "")
  }

  function take(text: string, serialIn: number | null): Pending | null {
    const index = serialIn === null ? -1 : pending.findIndex((item) => item.serial === serialIn)
    if (index < 0) {
      if (serialIn === null) for (const item of pending) track(item.id, { miss: "other" })
      return null
    }
    const [item] = pending.splice(index, 1)
    item.cancel()
    if (item.putBack !== undefined && ctx && ctx.ui.getEditorText() === item.putBack) ctx.ui.setEditorText("")
    return item
  }

  function settleSeen(item: Pending, text: string, turn: string): void {
    track(item.id, { state: "seen", turn, seenAt: host.now(), altered: text !== item.text })
    confirm(item.id)
  }

  function markedSerial(text: string): number | null {
    const at = text.indexOf(nonce)
    if (at < 0) return null
    let value = 0
    let digits = 0
    for (const char of text.slice(at + nonce.length)) {
      const digit = markAlphabet.indexOf(char)
      if (digit < 0) break
      value = value * markAlphabet.length + digit
      digits += 1
    }
    return digits ? value : null
  }

  function answerCheck(cmd: Command, gen: number): void {
    reply(gen, { op: "checked", request: cmd.request || "", check: cmd.id, ...report(cmd.request || "") })
  }

  function focusArgv(name: string | undefined): { argv: string[] } | { reason: string } {
    const definition = ((config && config.focusDefinitions) || []).find((d) => d.id === name)
    if (!name || !definition || !Array.isArray(definition.argv) || !Array.isArray(definition.requiresEnv)) return { reason: "unknownFocus" }
    const values: Record<string, string> = {}
    for (const key of definition.requiresEnv) {
      const value = host.env(key)
      if (!value) return { reason: "notInPlace" }
      if (value.startsWith("-")) return { reason: "unsafeValue" }
      values[key] = value
    }
    const argv = definition.argv.map((arg) => {
      const key = /^\{([^{}]+)\}$/.exec(arg)
      return key ? values[key[1]] : arg
    })
    if (!argv.length || argv.some((arg) => typeof arg !== "string") || !argv[0].startsWith("/")) return { reason: "unknownFocus" }
    return { argv }
  }

  async function focus(cmd: Command, gen: number): Promise<void> {
    const found = focusArgv(cmd.definition)
    if (!("argv" in found)) return refuse(gen, cmd.id, found.reason)
    if (!(host.now() < (cmd.expiresAt || 0))) return refuse(gen, cmd.id, "expired")
    if (!current(cmd.expectedSession, gen)) return refuse(gen, cmd.id, "sessionChanged")
    try {
      const result = await host.exec(found.argv[0], found.argv.slice(1), 3000)
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
    if (cmd.op === "check") return answerCheck(cmd, gen)
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
      polling = open("/poll", JSON.stringify({ session: target, instance, connection, wait: pollDeadline / 1000 }))
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
      if (adapter.retitle) adapter.retitle()
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
      const cancel = deadline(eventDeadline * 2, () => {
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
    if (answer === true) return `${app} will report your final reply when this turn ends. Say so in one short sentence and continue.`
    if (answer === false) return `Read Agent Replies Aloud is off in ${app}. Tell the user to turn on Read Agent Replies Aloud in ${app}\u2019s Agent settings and ask again. Nothing will be reported.`
    if (answer === "quiet") return `This conversation is disconnected from ${app}. Tell the user to reconnect it in ${app}\u2019s Agent settings. Nothing will be reported.`
    return `${app} didn\u2019t confirm the request, so the reply may not be reported. Tell the user.`
  }

  function commandAnswer(cancelling: boolean, answer: ReadAloud, running: boolean): string {
    const app = appName()
    if (answer === "quiet") return `This conversation is disconnected from ${app}. Reconnect it in ${app}\u2019s Agent settings.`
    if (answer === null) return cancelling ? `${app} didn\u2019t confirm the cancel.` : `${app} didn\u2019t confirm the request, so you may not get this reply.`
    if (cancelling) return `${app} won\u2019t report this reply.`
    if (answer === false) return `Read Agent Replies Aloud is off. Turn on Read Agent Replies Aloud in ${app}\u2019s Agent settings.`
    return running ? `${app} will report the result of this work.` : `${app} will report your next reply.`
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
        `to report when the current work is done. Call it once, then keep working. When this turn ends, ${app} reports your final reply. ` +
        `If the work is already finished, answer instead of calling it. Not for a plain "let me know".`,
      promptSnippet: `Have ${app} report your final reply when the user asks for it`,
      parameters: { type: "object", properties: {}, additionalProperties: false } as any,
      async execute() {
        return { content: [{ type: "text", text: toolAnswer(await askToReadAloud(true)) }], details: undefined }
      },
    })
    pi.registerCommand(command, {
      description: `Have ${app} report the reply when this work is done, or cancel that`,
      handler: async (args, context) => {
        const word = String(args || "").trim().toLowerCase()
        if (word && word !== "cancel") return context.ui.notify(`Use /${command} to get the reply when this work is done, or /${command} cancel.`, "info")
        const running = currentTurn !== null
        context.ui.notify(commandAnswer(word === "cancel", await askToReadAloud(word !== "cancel"), running), "info")
      },
    })
  }

  return {
    start(id, reason, context) {
      adopt(id, reason, context)
      if (!looping) {
        looping = true
        quietly(sender())
        quietly(pollLoop())
      }
    },
    end() {
      if (session) leave()
    },
    typed() {
      if (!session) return
      if (currentTurn !== null && ctx && adapter.quiet(ctx)) closeStaleTurn()
      prompts += 1
      observe({ op: "typed", session, prompts })
      const retitle = adapter.retitle
      if (!retitle) return
      if (titleCheck) titleCheck()
      titleCheck = host.after(retitleDelay, () => {
        titleCheck = null
        if (!dormant && session) retitle()
      })
    },
    accepted(text) {
      if (!session) return
      accepted(text)
    },
    turnStarted: beginTurn,
    turnFinished: finishTurn,
    paused(on) {
      if (on) answered = false
      if (on) stopStaleWatch()
      else if (session && currentTurn !== null && staleWatch === null) watchForStaleTurn()
    },
    cleared() {
      clears += 1
      for (const item of pending.splice(0)) item.cancel()
      steered.length = 0
      if (session && currentTurn !== null) closeStaleTurn()
    },
    assistantEnded(message) {
      if (!session || !message || (message as { role?: string }).role !== "assistant") return
      const stop = (message as { stopReason?: string }).stopReason
      lastFailed = stop === "error" || stop === "aborted"
      lastAnswer = lastFailed ? "" : messageText(message)
      repliedThisRun = true
      answered = !lastFailed && stop !== "toolUse" && !callsTool(message)
      if (lastAnswer.trim()) said = lastAnswer.trim().slice(-waitingSaidLimit)
    },
    userStarted(message) {
      const role = (message as { role?: string } | undefined)?.role
      if (!session || !message || (role !== "user" && role !== "custom")) return
      const after = currentTurn !== null && answered
      if (after) {
        finishTurn(false)
        beginTurn()
      }
      if (role === "custom") {
        if (after) lastFrom = "other"
        else if (repliedThisRun) lastPrompt = null
        return
      }
      lastFrom = null
      received(message)
    },
    compacting(on) {
      compacting = on
    },
    titled(text) {
      if (!session) return
      observe({ op: "title", session, text })
    },
    toolStarted(id, name, args) {
      tools.push({ id, name, args })
    },
    toolEnded(id) {
      const index = tools.findIndex((tool) => tool.id === id)
      if (index >= 0) tools.splice(index, 1)
    },
    waitBegan(kind, title, holds, tool) {
      promptsOpen += 1
      if (holds) holdsOpen += 1
      if (promptsOpen > 1 || !session) return
      const shown = tool ? tools.find((started) => started.id === tool.id) ?? { name: tool.name, args: undefined } : tools[tools.length - 1]
      waiting = waitingFor(kind, title, shown, said)
      observe({ op: "waiting", session, waiting })
    },
    waitEnded(holds) {
      if (promptsOpen === 0) return
      promptsOpen -= 1
      if (holds && holdsOpen > 0) holdsOpen -= 1
      if (promptsOpen > 0 || !session) return
      waiting = null
      observe({ op: "waiting", session })
    },
  }
}

export function connector(pi: ExtensionAPI, host: Host, settings: Settings): void {
  if (hostedByOmp(pi)) return
  const c = core(pi, host, settings, {
    agent: "pi", version: () => "", features, title: () => pi.getSessionName(),
    quiet: (context) => context.isIdle(), idleDelivery: "followUp", acceptsWhenSent: false,
  })

  pi.on("session_start", (event, context) => {
    if (context.mode !== "tui") return
    c.start(context.sessionManager.getSessionId(), event.reason, context)
  })

  pi.on("session_shutdown", () => c.end())

  pi.on("input", (event) => {
    if (event.source === "extension" && event.streamingBehavior === "steer") c.accepted(event.text || "")
    if (event.source === "interactive") c.typed()
  })

  pi.on("agent_start", () => c.turnStarted())

  pi.on("agent_settled", (event) => c.turnFinished(!!event.aborted))

  pi.on("message_end", (event) => c.assistantEnded(event.message))

  pi.on("message_start", (event) => c.userStarted(event.message))

  pi.on("session_before_compact", () => c.compacting(true))
  pi.on("session_compact", () => c.compacting(false))
  pi.on("session_compact_failed", () => c.compacting(false))

  pi.on("session_info_changed", (event) => c.titled(event.name || ""))

  pi.on("tool_execution_start", (event) => c.toolStarted(event.toolCallId, event.toolName, event.args))

  pi.on("tool_execution_end", (event) => c.toolEnded(event.toolCallId))

  pi.on("ui_prompt_start", (event) => c.waitBegan(event.kind, event.title, true))

  pi.on("ui_prompt_end", () => c.waitEnded(true))
}

type OmpEvents = (event: string, handler: (event: any, context: any) => unknown) => void

export function ompConnector(pi: ExtensionAPI, host: Host, settings: Settings): void {
  if (!hostedByOmp(pi)) return
  const on = pi.on.bind(pi) as unknown as OmpEvents
  let context: ExtensionContext | null = null
  let session: string | null = null
  let paused = false
  let cleared = false
  let lastStop: string | undefined
  let sentTitle = ""
  const waits = new Map<string, boolean>()

  const title = (): string => {
    const source = context ? (context.sessionManager as unknown as { titleSource?: string }).titleSource : undefined
    return source === "user" ? pi.getSessionName() || "" : ""
  }

  const c = core(pi, host, settings, {
    agent: "omp", version: () => ompVersion(pi), features: ompFeatures, title: () => title() || undefined,
    quiet: (ctx) => ctx.isIdle() && !paused, promptDelivery: "aside", acceptsWhenSent: true, retitle: () => retitle(),
  })

  const retitle = () => {
    const now = title()
    if (now === sentTitle) return
    sentTitle = now
    c.titled(now)
  }

  const begin = (id: string, kind: string, heading: string | undefined, holds: boolean, tool?: { id: string; name: string }) => {
    if (waits.has(id)) return
    waits.set(id, holds)
    c.waitBegan(kind, heading, holds, tool)
  }

  const finish = (id: string) => {
    const holds = waits.get(id)
    if (holds !== undefined && waits.delete(id)) c.waitEnded(holds)
  }

  const adopt = (ctx: ExtensionContext, reason: string) => {
    if (ctx.mode !== "tui") return
    waits.clear()
    paused = false
    cleared = false
    lastStop = undefined
    context = ctx
    session = ctx.sessionManager.getSessionId()
    sentTitle = title()
    c.start(session, reason, ctx)
  }

  on("session_start", (_event, ctx) => adopt(ctx, "resume"))

  on("session_switch", (event, ctx) => adopt(ctx, event.reason))

  on("session_branch", (_event, ctx) => {
    if (session !== null && ctx.sessionManager.getSessionId() !== session) adopt(ctx, "fork")
  })

  on("session_clear", () => {
    for (const id of [...waits.keys()]) finish(id)
    paused = false
    cleared = true
    lastStop = undefined
    c.compacting(false)
    c.cleared()
  })

  on("session_shutdown", () => {
    waits.clear()
    session = null
    context = null
    c.end()
  })

  on("input", (event) => {
    if (event.source !== "interactive") return
    c.typed()
    retitle()
  })

  on("agent_start", () => {
    paused = false
    cleared = false
    c.paused(false)
    c.turnStarted()
    retitle()
  })

  on("agent_end", (event) => {
    if (event.willContinue) {
      paused = true
      c.paused(true)
      return
    }
    paused = false
    for (const id of [...waits.keys()]) finish(id)
    c.compacting(false)
    if (cleared) {
      cleared = false
      return
    }
    c.turnFinished(lastStop === "aborted")
    lastStop = undefined
    retitle()
  })

  on("message_end", (event) => {
    if (event.message && event.message.role === "assistant") lastStop = event.message.stopReason
    c.assistantEnded(event.message)
  })

  on("message_start", (event) => c.userStarted(event.message))

  on("session_before_compact", () => c.compacting(true))
  on("auto_compaction_start", () => c.compacting(true))
  on("session_compact", () => c.compacting(false))
  on("auto_compaction_end", () => c.compacting(false))

  on("tool_execution_start", (event) => {
    c.toolStarted(event.toolCallId, event.toolName, event.args)
    if (event.toolName === "ask") begin(`tool:${event.toolCallId}`, "select", undefined, false)
  })

  on("tool_execution_end", (event) => {
    finish(`tool:${event.toolCallId}`)
    c.toolEnded(event.toolCallId)
  })

  on("tool_approval_requested", (event) =>
    begin(`approval:${event.toolCallId}`, "confirm", event.reason, false, { id: event.toolCallId, name: event.toolName }))
  on("tool_approval_resolved", (event) => finish(`approval:${event.toolCallId}`))

  on("plan_review_requested", (event) => begin(`plan:${event.reviewId}`, "confirm", event.title, true))
  on("plan_review_resolved", (event) => finish(`plan:${event.reviewId}`))
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

function promptDigest(text: string): string {
  const plain = (text.startsWith("\u200b") ? text.slice(1) : text).trim()
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(plain)) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, "0")
}

function callsTool(message: unknown): boolean {
  const content = (message as { content?: unknown }).content
  return Array.isArray(content) && content.some((part) => part && typeof part === "object" && (part as { type?: string }).type === "toolCall")
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
    readBase64: (path) => readFile(path, "base64"),
    after: (ms, fn) => {
      const timer = setTimeout(fn, ms)
      if (typeof timer.unref === "function") timer.unref()
      return () => clearTimeout(timer)
    },
    exec: async (command, args, timeoutMs) => {
      const result = await pi.exec(command, args, { timeout: timeoutMs })
      return { code: result.code }
    },
    watch: (folder, changed, broken) => {
      try {
        const watcher = watch(folder, { persistent: false }, () => changed())
        watcher.on("error", () => {
          watcher.close()
          broken()
        })
        return () => watcher.close()
      } catch (err) {
        return null
      }
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
  const start = installedFor === "omp" ? ompConnector : connector
  start(pi, nodeHost(pi), { configPath, loadedFrom, builtVersion })
}
