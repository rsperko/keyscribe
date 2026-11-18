export type Response = { status: number; ok: boolean; text: string }
export type Exchange = { response: Promise<Response>; cancel: () => void }
export type Host = {
  now: () => number
  read: (path: string) => Promise<string>
  after: (ms: number, fn: () => void) => () => void
  post: (socketPath: string, path: string, body: string, token: string) => Exchange
  random: () => string
  log: (message: string) => void
  needsConfiguration: (message: string) => void
  watch: (path: string, fn: () => void) => () => void
  labelled: () => void
}
export type Thread = { id: string; status: string }
export type WindowReport = { window: string; focused: boolean; thread: string | null; draft?: boolean; newThread?: boolean }
export type Pane = { threadId: string | null; isFocused: boolean }
export type Bb = {
  listThreads: () => Promise<Thread[]>
  history: (thread: string) => Promise<string[]>
  interaction: (thread: string, id: string) => Promise<string | null>
  on: (event: string, handler: (payload: any) => void) => void
  compose: (window: string, thread: string | null, text: string) => Promise<Composed | null>
}
export type Composed =
  | { outcome: "sent"; joined: string }
  | { outcome: "failed"; alone?: boolean; why?: string; said?: string }
  | { outcome: "unclear"; why?: string }
  | { outcome: "empty" | "blocked" }
export type ComposeAsk = { id: string; window: string; thread: string | null; text: string }
export type ComposeAnswer = { id: string } & Composed
export type Waiting = { kind?: string; title?: string; tool?: string; detail?: string }
export type ReadAloud = boolean | "quiet" | null

type Config = { protocol: number; socketPath: string; tokenPath: string; readyPath: string; installation: string; instance: string; version?: string; appName?: string }
type Member = {
  status: string
  helloed: boolean
  greeting: boolean
  quiet: boolean
  turn: string | null
  next: string | null | undefined
  chain: Promise<void>
  waiting: { id: string; prompt: Waiting; openedAt: number; stop: () => void } | null
  unsaid: boolean
  resay: boolean
  unstarted: { turn: string; next: string | null | undefined } | null
}

const features = ["promptDigest", "readiness", "shown", "notify", "label", "merge", "start"]
const newThreadPage = "new conversation"
const labelLimit = 200
const busy = new Set(["active", "starting", "stopping"])
const answerLimit = 8192
const eventDeadline = 2000
const pollDeadline = 30000
const backoff = [10000, 30000, 60000]
const greetingLimit = 8
const windowSilence = 15000
const windowSweep = 5000
const shownRetry = 5000
const waitingCheck = 5000
const waitingCheckLater = 30000
const waitingCheckSlowsAfter = 60000
const readAloudDeadline = 4000
const joinedLimit = 32
const waitingTitleLimit = 300
const waitingDetailLimit = 1000

function clean(value: unknown, limit: number): string | undefined {
  if (typeof value !== "string") return undefined
  const trimmed = value.trim()
  return trimmed ? trimmed.slice(0, limit) : undefined
}

function described(kind: string, title: unknown, tool?: unknown, detail?: unknown): Waiting {
  const found: Waiting = { kind }
  const t = clean(title, waitingTitleLimit)
  if (t) found.title = t
  const named = clean(tool, waitingTitleLimit)
  if (named) found.tool = named
  const d = clean(detail, waitingDetailLimit)
  if (d) found.detail = d
  return found
}

export function waitingFor(interaction: any): Waiting {
  const payload = interaction?.payload
  if (!payload || typeof payload !== "object") return {}
  if (payload.kind === "approval") {
    const subject = payload.subject ?? {}
    const reason = payload.reason
    switch (subject.kind) {
      case "command": return described("confirm", reason, "command", subject.command)
      case "file_change": return described("confirm", reason, undefined, subject.writeScope)
      case "permission_grant": return described("confirm", reason, subject.toolName)
      case "plan": return described("confirm", reason, undefined, subject.plan)
      case "tool_use": return described("confirm", reason ?? subject.presentation?.title ?? subject.presentation?.label?.pending, subject.tool, subject.presentation?.detail)
      default: return described("confirm", reason)
    }
  }
  if (payload.kind === "user_question") {
    const question = Array.isArray(payload.questions) ? payload.questions[0] : undefined
    const options = Array.isArray(question?.options) ? question.options.map((option: any) => option?.label).filter((label: unknown) => typeof label === "string") : []
    return options.length ? described("select", question?.prompt, undefined, options.join(", ")) : described("input", question?.prompt)
  }
  return described("custom", payload.title)
}

export class ComposerAnswers {
  private readonly latest = new Map<string, number>()
  private readonly answers = new Map<string, string>()
  private requests = 0
  private readonly limit: number

  constructor(limit = 32) {
    this.limit = limit
  }

  begin(composer: string): number {
    const request = ++this.requests
    this.latest.delete(composer)
    this.latest.set(composer, request)
    for (const oldest of this.latest.keys()) {
      if (this.latest.size <= this.limit) break
      this.latest.delete(oldest)
      this.answers.delete(oldest)
    }
    return request
  }

  settle(composer: string, request: number, answer: string): boolean {
    if (this.latest.get(composer) !== request) return false
    this.answers.set(composer, answer)
    return true
  }

  answer(composer: string): string | undefined {
    return this.answers.get(composer)
  }
}

export function appNameOf(settings: { appName?: string } | null | undefined): string {
  return settings?.appName?.trim() || "the voice app"
}

export function commandAnswer(app: string, cancelling: boolean, answer: ReadAloud, running: boolean): string {
  if (answer === "quiet") return `This conversation is disconnected from ${app}. Reconnect it in ${app}\u2019s Agent settings.`
  if (answer === null) return cancelling ? `${app} didn\u2019t confirm the cancel.` : `${app} didn\u2019t confirm the request, so you may not get this reply.`
  if (cancelling) return `${app} won\u2019t report this reply.`
  if (answer === false) return `Read Agent Replies Aloud is off. Turn on Read Agent Replies Aloud in ${app}\u2019s Agent settings.`
  return running ? `${app} will report the result of this work.` : `${app} will report your next reply.`
}

export function readAloudReply(app: string, answer: ReadAloud): string {
  if (answer === true) return `${app} will report your final reply when this turn ends. Say so in one short sentence and continue.`
  if (answer === false) return `Read Agent Replies Aloud is off in ${app}. Tell the user to turn on Read Agent Replies Aloud in ${app}’s Agent settings and ask again. Nothing will be reported.`
  if (answer === "quiet") return `This conversation is disconnected from ${app}. Tell the user to reconnect it in ${app}’s Agent settings. Nothing will be reported.`
  return `${app} didn’t confirm the request, so the reply may not be reported. Tell the user.`
}

export function shownThread(route: string | null, panes: readonly Pane[] | null): string | null {
  if (!route) return null
  const focused = panes?.find((pane) => pane.isFocused)
  return !focused || focused.threadId === route ? route : null
}

export type ComposerLike = {
  readonly scope: { kind: string; threadId?: string }
  readonly isEmpty: boolean
  readonly isSubmittingBlocked: boolean
  readonly submittingBlockedReason?: string | null
  readonly text: string
  insert(text: string, options: { at: "end" }): void
  submit(options?: { experimental_mode: "steer-if-active" }): Promise<void>
}

export function runsAsCommand(text: string): boolean {
  return /^[/!]/.test(text.trimStart())
}

const registerPause = 16
const registerTries = 60
const resendPause = 100
const resendWindow = 1500
const emptyDraftRefusals = ["Enter a prompt or attach a file.", "Type a message first."]

export async function composeInto(
  composers: readonly ComposerLike[], thread: string | null, said: string, current: () => readonly ComposerLike[] = () => composers,
): Promise<Composed> {
  const mine = (box: ComposerLike) => thread === null ? box.scope.kind === "new-thread" : box.scope.kind === "thread" && box.scope.threadId === thread
  const boxes = composers.filter(mine)
  if (thread === null ? boxes.length === 0 : boxes.every((box) => box.isEmpty)) return { outcome: "empty" }
  const box = boxes[0]
  const alone = box.isEmpty
  if (boxes.length > 1 || (!alone && box.isSubmittingBlocked) || runsAsCommand(box.text)) return { outcome: "blocked" }
  const emptyRefusal = box.isEmpty ? box.submittingBlockedReason?.trim() || null : null
  const draft = box.text
  const joined = draft + (draft && !/\s$/.test(draft) ? " " : "") + said
  box.insert(joined.slice(draft.length), { at: "end" })
  let shown = box
  const ready = (box: ComposerLike) => !box.isSubmittingBlocked
  for (let tries = 0; !ready(shown) && tries < registerTries; tries++) {
    await new Promise((resolve) => setTimeout(resolve, registerPause))
    shown = current().find(mine) ?? shown
  }
  const holdsWhatWasTyped = (box: ComposerLike) => box.text.trim() === joined.trim()
  const firstTry = Date.now()
  for (;;) {
    const blockedFor = shown.isSubmittingBlocked ? shown.submittingBlockedReason?.trim() || null : null
    try {
      await (thread === null ? shown.submit() : shown.submit({ experimental_mode: "steer-if-active" }))
      return { outcome: "sent", joined }
    } catch (error) {
      const said = error instanceof Error && error.message.trim() ? error.message.trim().slice(0, 200) : undefined
      const unsentAsEmpty = said !== undefined && (said === emptyRefusal || emptyDraftRefusals.includes(said))
      const catchingUp = (box: ComposerLike) => unsentAsEmpty && holdsWhatWasTyped(box) && !box.isSubmittingBlocked
      shown = current().find(mine) ?? shown
      if (catchingUp(shown) && Date.now() - firstTry < resendWindow) {
        await new Promise((resolve) => setTimeout(resolve, resendPause))
        shown = current().find(mine) ?? shown
        if (catchingUp(shown)) continue
      }
      const seen = holdsWhatWasTyped(shown) ? "after bb showed the words" : "before bb showed the words"
      const why = `${said ?? "no reason given"} (${seen})`
      if (!unsentAsEmpty && (blockedFor === null || said !== blockedFor)) return { outcome: "unclear", why }
      const failed = { why, ...(said ? { said } : {}) }
      return alone ? { outcome: "failed", alone: true, ...failed } : { outcome: "failed", ...failed }
    }
  }
}

export const composeChannel = "compose"

export function isComposeAsk(value: unknown): value is ComposeAsk {
  if (!value || typeof value !== "object") return false
  const ask = value as Record<string, unknown>
  return [ask.id, ask.window].every((part) => typeof part === "string" && part.length > 0 && part.length <= 128)
    && (ask.thread === null || (typeof ask.thread === "string" && ask.thread.length > 0 && ask.thread.length <= 128))
    && typeof ask.text === "string"
}

function isComposeStart(value: unknown): value is { id: string } {
  if (!value || typeof value !== "object") return false
  const id = (value as Record<string, unknown>).id
  return typeof id === "string" && id.length > 0 && id.length <= 128
}

function isComposeAnswer(value: unknown): value is ComposeAnswer {
  if (!value || typeof value !== "object") return false
  const answer = value as Record<string, unknown>
  if (typeof answer.id !== "string" || answer.id.length > 128) return false
  if (answer.outcome === "sent") return typeof answer.joined === "string"
  if (answer.outcome === "failed") {
    return (answer.alone === undefined || typeof answer.alone === "boolean") && (answer.why === undefined || typeof answer.why === "string")
      && (answer.said === undefined || typeof answer.said === "string")
  }
  if (answer.outcome === "unclear") return answer.why === undefined || typeof answer.why === "string"
  return answer.outcome === "empty" || answer.outcome === "blocked"
}

type Checked<T> = { value: T } | { issues: { message: string }[] }
type Schema<T> = {
  readonly "~standard": {
    readonly version: 1; readonly vendor: string; readonly validate: (value: unknown) => Checked<T>; readonly types?: { readonly input: T; readonly output: T }
  }
}

function schema<T>(accepts: (value: unknown) => value is T, message: string): Schema<T> {
  return { "~standard": { version: 1, vendor: "keyscribe", validate: (value) => accepts(value) ? { value } : { issues: [{ message }] } } }
}

function isWindowReport(value: unknown): value is WindowReport {
  if (!value || typeof value !== "object") return false
  const report = value as Record<string, unknown>
  return typeof report.window === "string" && report.window.length > 0 && report.window.length <= 64 && typeof report.focused === "boolean"
    && (report.thread === null || (typeof report.thread === "string" && report.thread.length <= 128))
    && (report.draft === undefined || typeof report.draft === "boolean")
    && (report.newThread === undefined || typeof report.newThread === "boolean")
}

function isThreadKeys(value: unknown): value is { keys: string[] } {
  if (!value || typeof value !== "object") return false
  const keys = (value as Record<string, unknown>).keys
  return Array.isArray(keys) && keys.length <= 1000 && keys.every((key) => typeof key === "string" && key.length <= 128)
}

function isReadAloudAsk(value: unknown): value is { thread: string; on: boolean } {
  if (!value || typeof value !== "object") return false
  const ask = value as Record<string, unknown>
  return typeof ask.thread === "string" && ask.thread.length > 0 && ask.thread.length <= 128 && typeof ask.on === "boolean"
}

function isMessage(value: unknown): value is { message: string } {
  return !!value && typeof value === "object" && typeof (value as Record<string, unknown>).message === "string"
}

function isLabels(value: unknown): value is Record<string, string | null> {
  return !!value && typeof value === "object" && Object.values(value).every((label) => label === null || typeof label === "string")
}

export const rpcContract = {
  window: {
    input: schema(isWindowReport, "expected { window, focused, thread }"),
    output: schema((value): value is null => value === null, "expected null"),
  },
  labels: {
    input: schema(isThreadKeys, "expected { keys }"),
    output: schema(isLabels, "expected a name or null for each key"),
  },
  readAloud: {
    input: schema(isReadAloudAsk, "expected { thread, on }"),
    output: schema(isMessage, "expected { message }"),
  },
  composing: {
    input: schema(isComposeStart, "expected { id }"),
    output: schema((value): value is { go: boolean } => !!value && typeof (value as Record<string, unknown>).go === "boolean", "expected { go }"),
  },
  composed: {
    input: schema(isComposeAnswer, "expected { id, outcome }"),
    output: schema((value): value is null => value === null, "expected null"),
  },
}

export function rowLabel(label: string | null | undefined, title: string | null): string | null {
  const name = (label ?? "").replace(/^[\s“"]+|[\s”"]+$/g, "")
  if (!name) return null
  const plain = (text: string) => text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim()
  return title !== null && plain(title) === plain(name) ? null : name
}

export function promptDigest(text: string): string {
  const plain = (text.startsWith("​") ? text.slice(1) : text).trim()
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(plain)) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, "0")
}

function key(thread: string, instance: string): string {
  return thread.replace(/%/g, "%25").replace(/@/g, "%40") + "@" + instance
}

function text(content: unknown): string | null {
  if (!Array.isArray(content)) return null
  const parts = content.filter((item) => item && item.type === "text" && typeof item.text === "string").map((item) => item.text as string)
  return parts.length ? parts.join("\n") : null
}

function folder(path: string): string {
  const index = path.lastIndexOf("/")
  return index > 0 ? path.slice(0, index) : "/"
}

export function keyscribe(bb: Bb, host: Host, configPaths: string[]): {
  stop: () => void
  window: (report: WindowReport) => void
  readAloud: (thread: string, on?: boolean) => Promise<ReadAloud>
  command: (thread: string, on: boolean) => Promise<string>
  labels: (threads: string[]) => Record<string, string | null>
  settings: Promise<{ appName?: string; instance?: string } | null>
} {
  const connection = "bb-" + host.random()
  const members = new Map<string, Member>()
  const names = new Map<string, string>()
  const queued = new Map<string, { thread: string; text: string }>()
  const joinedAs = new Map<string, string>()
  const startedAs = new Map<string, string>()
  let config: Config | null = null
  let token = ""
  let launch: string | null = null
  let connected = false
  let connecting = false
  let listed = false
  let stopped = false
  let failures = 0
  let retry: (() => void) | null = null
  let unwatch: (() => void) | null = null
  let polling: { cancel: () => void } | null = null
  const windows = new Map<string, { thread: string | null; draft: boolean; newThread: boolean; focused: boolean; focusedAt: number; seenAt: number }>()
  let focusings = 0
  let turnCount = 0
  let wanted: string | null = null
  let wantedDraft = false
  let wantedStart = false
  let told: string | null | undefined
  let toldDraft = false
  let toldStart = false
  let telling = false
  let retelling: (() => void) | null = null
  let sweeping: (() => void) | null = null
  let settled: (value: Config | null) => void = () => {}
  const settings = new Promise<Config | null>((resolve) => { settled = resolve })

  const instanceOf = (thread: string) => `${connection}/${thread}`
  const newTurn = () => "t-" + host.random() + "-" + host.now() + "-" + (++turnCount)
  const sessionOf = (thread: string) => key(thread, config ? config.instance : "")

  function member(thread: string, status = "idle"): { member: Member; added: boolean } {
    const found = members.get(thread)
    if (found) return { member: found, added: false }
    const made: Member = {
      status, helloed: false, greeting: false, quiet: false, turn: busy.has(status) ? newTurn() : null, next: undefined, chain: Promise.resolve(),
      waiting: null, unsaid: false, resay: false, unstarted: null,
    }
    members.set(thread, made)
    return { member: made, added: true }
  }

  function post(path: string, body: object, deadline: number): Promise<Response | null> {
    if (!config || stopped) return Promise.resolve(null)
    const exchange = host.post(config.socketPath, path, JSON.stringify(body), token)
    const clear = host.after(deadline, () => exchange.cancel())
    return exchange.response.then(
      (response) => { clear(); return response },
      () => { clear(); return null })
  }

  function schedule() {
    if (stopped || retry) return
    const delay = backoff[Math.min(failures, backoff.length - 1)]
    failures += 1
    retry = host.after(delay, () => {
      retry = null
      void connect()
    })
  }

  function wake() {
    if (stopped || connected || connecting) return
    retry?.()
    retry = null
    void connect()
  }

  function forgetNames() {
    if (!names.size) return
    names.clear()
    host.labelled()
  }

  function fail() {
    if (connected) host.log("lost the connection to the app; trying again later")
    connected = false
    polling?.cancel()
    polling = null
    schedule()
  }

  function stop(reason?: string) {
    if (stopped) return
    if (reason) host.log(reason)
    stopped = true
    settled(config)
    connected = false
    forgetNames()
    polling?.cancel()
    polling = null
    retry?.()
    retry = null
    unwatch?.()
    unwatch = null
    for (const m of members.values()) m.waiting?.stop()
    sweeping?.()
    sweeping = null
    retelling?.()
    retelling = null
  }

  async function readConfig(): Promise<Config | null> {
    for (const path of configPaths) {
      try {
        return JSON.parse(await host.read(path)) as Config
      } catch {}
    }
    return null
  }

  async function connect() {
    if (stopped || connecting || connected) return
    connecting = true
    try {
      if (!config) {
        config = await readConfig()
        settled(config)
        if (stopped) return
        if (!config) {
          host.needsConfiguration("Install this plugin again from the app's settings.")
          return stop("its settings file is missing")
        }
        unwatch = host.watch(folder(config.readyPath), wake)
      }
      let ready: any
      try {
        ready = JSON.parse(await host.read(config.readyPath))
      } catch {
        ready = null
      }
      if (stopped) return
      if (!ready || typeof ready.launch !== "string") {
        forgetNames()
        if (failures === 0) host.log("the app is not running; waiting for it")
        return schedule()
      }
      token = (await host.read(config.tokenPath)).trim()
      if (ready.launch !== launch) {
        if (launch !== null) forgetNames()
        for (const m of members.values()) m.helloed = false
      }
      launch = ready.launch
      if (!listed) {
        for (const thread of await bb.listThreads()) member(thread.id, thread.status)
        member(newThreadPage)
        listed = true
      }
    } catch {
      return schedule()
    } finally {
      connecting = false
    }
    if (stopped) return
    connected = true
    host.log("connected to the app")
    await greetAll()
  }

  async function greetAll() {
    const waiting = [...members.keys()].filter((thread) => {
      const m = members.get(thread)!
      return (!m.helloed || m.resay) && !m.greeting
    })
    const results: Array<"ok" | "failed" | "gone" | number> = []
    let next = 0
    const worker = async () => {
      while (next < waiting.length && !stopped) results.push(await greet(waiting[next++]))
    }
    await Promise.all(Array.from({ length: Math.min(greetingLimit, waiting.length) }, worker))
    if (!connected || stopped) return
    const refused = results.find((r) => typeof r === "number")
    if (refused !== undefined) return stop(`the app refused this plugin (${refused}); install it again from the app's settings`)
    if (results.some((r) => r === "failed")) return fail()
    failures = 0
    told = undefined
    tell()
    repoll()
  }

  async function greet(thread: string): Promise<"ok" | "failed" | "gone" | number> {
    const m = members.get(thread)
    if (!m || !config) return "gone"
    m.greeting = true
    m.resay = false
    const announced = m.waiting
    const response = await post("/event", {
      op: "hello", protocol: config.protocol, agent: "bb", agentVersion: "", instance: instanceOf(thread), session: sessionOf(thread),
      pid: 0, features, idle: !busy.has(m.status), gap: true, connection, installation: config.installation, version: config.version,
      ...(m.waiting ? { waiting: m.waiting.prompt } : {}),
      ...(m.turn ? { turn: m.turn } : {}),
    }, eventDeadline)
    m.greeting = false
    if (members.get(thread) !== m) return "gone"
    if (!response || response.status === 0) {
      m.resay = true
      return "failed"
    }
    if (response.status === 403 || response.status === 426) return response.status
    if (!response.ok) {
      m.resay = true
      return "failed"
    }
    try {
      m.quiet = JSON.parse(response.text)?.quiet === true
    } catch {
      m.quiet = false
    }
    m.helloed = true
    if (!m.quiet) m.unsaid = false
    if (m.waiting !== announced) reportWaiting(thread, m)
    reportStart(thread, m)
    return "ok"
  }

  function repoll() {
    polling?.cancel()
    polling = null
    if (!connected || stopped || !config) return
    const list = [...members.entries()].filter(([, m]) => m.helloed).map(([thread]) => ({ session: sessionOf(thread), instance: instanceOf(thread) }))
    if (!list.length) return
    let cancelled = false
    const exchange = host.post(config.socketPath, "/poll", JSON.stringify({ members: list, connection }), token)
    const clear = host.after(pollDeadline, () => exchange.cancel())
    const current = { cancel: () => { cancelled = true; clear(); exchange.cancel() } }
    polling = current
    exchange.response.then((response) => response, () => null).then((response) => {
      clear()
      if (cancelled || polling !== current) return
      polling = null
      void answered(response)
    })
  }

  async function answered(response: Response | null) {
    if (stopped) return
    if (!response || (response.status !== 200 && response.status !== 409)) return fail()
    if (response.status === 409) {
      for (const m of members.values()) m.helloed = false
      return greetAll()
    }
    let parsed: any
    try {
      parsed = JSON.parse(response.text)
    } catch {
      return fail()
    }
    const commands: any[] = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.commands) ? parsed.commands : []
    const readmitted: string[] = []
    if (commands.some((c) => c && c.op === "retire")) return stop("the app retired this plugin")
    for (const command of commands) {
      const thread = [...members.keys()].find((t) => sessionOf(t) === command?.expectedSession)
      if (!thread || typeof command.id !== "string") continue
      const m = members.get(thread)!
      if (command.op === "quiet" || command.op === "admit") {
        m.quiet = command.op === "quiet"
        told = undefined
        if (command.op === "admit" && m.unsaid) readmitted.push(thread)
      }
      if (command.op === "status" && typeof command.text === "string" && names.get(thread) !== command.text.slice(0, labelLimit)) {
        names.set(thread, command.text.slice(0, labelLimit))
        host.labelled()
      }
      void post("/event", { op: "ack", request: command.id, instance: instanceOf(thread), connection }, eventDeadline)
      if (command.op === "submit") void join(thread, command)
      if (command.op === "start") void start(thread, command)
    }
    const unknown: string[] = Array.isArray(parsed?.unknown) ? parsed.unknown : []
    for (const [thread, m] of members) if (unknown.includes(instanceOf(thread)) || readmitted.includes(thread)) m.helloed = false
    if (unknown.length || readmitted.length) return greetAll()
    tell()
    repoll()
  }

  function report(thread: string, body: () => Promise<object | null>, state = false) {
    const m = members.get(thread)
    if (!m) return
    const rehello = () => {
      if (stopped || members.get(thread) !== m) return
      m.resay = true
      m.chain = m.chain.then(() => {
        if (connected && !stopped && m.resay) void greetAll()
      })
    }
    m.chain = m.chain.then(async () => {
      if (state && m.quiet) m.unsaid = true
      if (stopped || m.quiet || !m.helloed) return
      if (!connected) return state ? rehello() : undefined
      const event = await body()
      if (!event || stopped || !m.helloed || m.quiet) return
      if (!connected) return state ? rehello() : undefined
      const response = await post("/event", { ...event, instance: instanceOf(thread), connection }, eventDeadline)
      if (response?.status === 409 && members.get(thread) === m) {
        m.helloed = false
        if (connected) void greetAll()
      } else if (state && !response?.ok) rehello()
    })
  }

  function reportWaiting(thread: string, m: Member) {
    const prompt = m.waiting?.prompt
    report(thread, async () => (prompt ? { op: "waiting", session: sessionOf(thread), waiting: prompt } : { op: "waiting", session: sessionOf(thread) }), true)
  }

  async function startedPrompt(thread: string, next: string | null | undefined): Promise<string | undefined> {
    if (next !== undefined) return next === null ? undefined : digestFor(thread, next)
    try {
      const waiting = new Set([...queued.values()].filter((q) => q.thread === thread).map((q) => q.text))
      const newest = (await bb.history(thread)).find((entry) => !waiting.has(entry))
      return newest === undefined ? undefined : digestFor(thread, newest)
    } catch {
      return undefined
    }
  }

  function digestFor(thread: string, text: string): string {
    return promptDigest(joinedAs.get(thread + "\n" + text.trim()) ?? startedAs.get(text.trim()) ?? text)
  }

  function remember(map: Map<string, string>, key: string, said: string) {
    map.delete(key)
    map.set(key, said)
    for (const oldest of map.keys()) {
      if (map.size <= joinedLimit) break
      map.delete(oldest)
    }
  }

  function frontWindow(): { id: string; thread: string | null; draft: boolean; newThread: boolean } | null {
    const now = host.now()
    for (const [id, w] of windows) if (now - w.seenAt > windowSilence) windows.delete(id)
    const fresh = [...windows].map(([id, w]) => ({ id, ...w }))
    const focusedNow = fresh.filter((w) => w.focused)
    const pool = (focusedNow.length ? focusedNow : fresh).filter((w) => w.focusedAt > 0)
    let best: { id: string; thread: string | null; draft: boolean; newThread: boolean; focusedAt: number } | null = null
    for (const w of pool) if (!best || w.focusedAt > best.focusedAt) best = w
    return best
  }

  function front(): string | null {
    return frontWindow()?.thread ?? null
  }

  async function join(thread: string, command: any) {
    const answer = (body: object) => post("/event", { ...body, request: command.id, instance: instanceOf(thread), connection }, eventDeadline)
    if (command.merge !== true || typeof command.text !== "string") return answer({ op: "refused", reason: "unsupported" })
    if (runsAsCommand(command.text)) return answer({ op: "refused", reason: "draft" })
    const shown = frontWindow()
    if (!shown || shown.thread !== thread) return answer({ op: "refused", reason: "empty" })
    const composed = await bb.compose(shown.id, thread, command.text).catch(() => null)
    if (!composed || stopped) return
    if (composed.outcome === "unclear") host.log(`bb may not have sent a dictation: ${composed.why ?? "no reason given"}`)
    if (composed.outcome !== "sent") {
      const reason = composed.outcome === "empty" ? "empty" : composed.outcome === "failed" ? "added" : composed.outcome === "unclear" ? "unclear" : "draft"
      return answer({ op: "refused", reason })
    }
    remember(joinedAs, thread + "\n" + composed.joined.trim(), command.text)
    return answer({ op: "submitted", turn: "" })
  }

  async function start(thread: string, command: any) {
    const answer = (body: object) => post("/event", { ...body, request: command.id, instance: instanceOf(thread), connection }, eventDeadline)
    if (typeof command.text !== "string") return answer({ op: "refused", reason: "unsupported" })
    if (runsAsCommand(command.text)) return answer({ op: "refused", reason: "command" })
    const shown = frontWindow()
    if (!shown || shown.thread !== null || !shown.newThread) return answer({ op: "refused", reason: "gone" })
    const composed = await bb.compose(shown.id, null, command.text).catch(() => null)
    if (!composed || stopped) return
    if (composed.outcome === "sent") {
      remember(startedAs, composed.joined.trim(), command.text)
      return answer({ op: "submitted", turn: "", ...(composed.joined.trim() !== command.text.trim() ? { withDraft: true } : {}) })
    }
    if (composed.outcome === "failed") host.log(`bb did not start a new thread: ${composed.why ?? "no reason given"}`)
    if (composed.outcome === "unclear") {
      host.log(`bb may not have started a new thread: ${composed.why ?? "no reason given"}`)
      return answer({ op: "refused", reason: "unclear" })
    }
    const reason = composed.outcome === "failed" ? (composed.alone ? "filled" : "added") : composed.outcome === "empty" ? "gone" : "draft"
    const said = composed.outcome === "failed" ? composed.said : undefined
    return answer({ op: "refused", reason, ...(said ? { detail: said } : {}) })
  }

  function reachable(thread: string | null | undefined): thread is string {
    const m = thread ? members.get(thread) : undefined
    return !!m && m.helloed && !m.quiet
  }

  function tell() {
    if (!connected || stopped || telling || !config) return
    const target = reachable(wanted) ? wanted : null
    const draft = target !== null && wantedDraft
    const starts = wanted === null && wantedStart
    if (told !== undefined && told === target && toldDraft === draft && toldStart === starts) return
    const via = target ?? (reachable(told) ? told : [...members.keys()].find(reachable))
    if (!via) {
      told = target
      toldDraft = draft
      toldStart = starts
      return
    }
    telling = true
    retelling?.()
    retelling = null
    const body = { op: "shown", session: sessionOf(via), on: target !== null, draft, ...(starts ? { newConversation: true } : {}), instance: instanceOf(via), connection }
    void post("/event", body, eventDeadline).then((response) => {
      telling = false
      if (response?.ok) {
        told = target
        toldDraft = draft
        toldStart = starts
        return tell()
      }
      if (response?.status === 409 && members.get(via)) {
        members.get(via)!.helloed = false
        return void greetAll()
      }
      if (!stopped && !retelling) retelling = host.after(shownRetry, () => { retelling = null; tell() })
    })
  }

  function settleFront() {
    const shown = frontWindow()
    wanted = shown?.thread ?? null
    wantedDraft = shown?.draft ?? false
    wantedStart = shown?.newThread ?? false
    tell()
    if (windows.size && !sweeping && !stopped) {
      sweeping = host.after(windowSweep, () => {
        sweeping = null
        settleFront()
      })
    }
  }

  function window(report: WindowReport) {
    if (stopped || typeof report?.window !== "string") return
    const now = host.now()
    const known = windows.get(report.window)
    if (!known) host.log("a bb window started reporting")
    windows.set(report.window, {
      thread: typeof report.thread === "string" ? report.thread : null,
      draft: report.draft === true,
      newThread: report.thread === null && report.newThread === true,
      focused: report.focused === true,
      focusedAt: report.focused === true && !known?.focused ? ++focusings : known?.focusedAt ?? 0,
      seenAt: now,
    })
    settleFront()
  }

  function changed() {
    if (stopped || !connected) return
    if ([...members.values()].some((m) => !m.helloed && !m.greeting)) return void greetAll()
    tell()
    repoll()
  }

  function arrived(thread: any, created: boolean) {
    if (!thread?.id || members.has(thread.id)) return
    const { member: m } = member(thread.id, thread.status)
    if (created && m.turn) m.unstarted = { turn: m.turn, next: undefined }
    changed()
  }

  bb.on("thread.created", ({ thread }) => arrived(thread, true))
  bb.on("thread.unarchived", ({ thread }) => arrived(thread, false))
  const leave = ({ thread }: any) => {
    if (!thread?.id) return
    members.get(thread.id)?.waiting?.stop()
    if (!members.delete(thread.id)) return
    for (const [id, q] of queued) if (q.thread === thread.id) queued.delete(id)
    names.delete(thread.id)
    changed()
  }
  bb.on("thread.archived", leave)
  bb.on("thread.deleted", leave)
  bb.on("message.queued", ({ entry }) => {
    const said = text(entry?.content)
    if (!entry?.id || !entry.threadId || entry.initiator === "system" || said === null) return
    queued.set(entry.id, { thread: entry.threadId, text: said })
  })
  bb.on("message.cancelled", ({ entry }) => { if (entry?.id) queued.delete(entry.id) })
  bb.on("message.dispatched", ({ entry }) => {
    if (!entry?.id || !entry.threadId) return
    queued.delete(entry.id)
    const m = members.get(entry.threadId)
    if (!m) return
    m.next = entry.initiator === "system" ? null : text(entry.content)
  })
  bb.on("thread.active", ({ thread }) => {
    if (!thread?.id) return
    const { member: m, added } = member(thread.id, "active")
    m.status = "active"
    const next = m.next
    m.next = undefined
    const turn = newTurn()
    m.turn = turn
    m.unstarted = { turn, next }
    if (added) return changed()
    reportStart(thread.id, m)
  })

  function reportStart(thread: string, m: Member) {
    const started = m.unstarted
    if (!started) return
    report(thread, async () => {
      if (m.unstarted !== started) return null
      m.unstarted = null
      const prompt = await startedPrompt(thread, started.next)
      const event = { op: "turnStarted", session: sessionOf(thread), turn: started.turn }
      return prompt === undefined ? event : { ...event, prompt }
    })
  }
  function stopWaiting(thread: string, m: Member) {
    if (!m.waiting) return
    m.waiting.stop()
    m.waiting = null
    reportWaiting(thread, m)
  }

  function checkWaiting(thread: string, m: Member, entry: NonNullable<Member["waiting"]>) {
    const delay = host.now() - entry.openedAt < waitingCheckSlowsAfter ? waitingCheck : waitingCheckLater
    entry.stop = host.after(delay, () => {
      void (async () => {
        let status: string | null
        try {
          status = await bb.interaction(thread, entry.id)
        } catch {
          status = "pending"
        }
        if (stopped || m.waiting !== entry || members.get(thread) !== m) return
        if (status === "pending") checkWaiting(thread, m, entry)
        else stopWaiting(thread, m)
      })()
    })
  }

  bb.on("interaction.pending", ({ thread, interaction }) => {
    const id = thread?.id ?? interaction?.threadId
    const m = typeof id === "string" ? members.get(id) : undefined
    if (!m || interaction?.status !== "pending" || typeof interaction.id !== "string") return
    m.waiting?.stop()
    const entry = { id: interaction.id as string, prompt: waitingFor(interaction), openedAt: host.now(), stop: () => {} }
    m.waiting = entry
    reportWaiting(id, m)
    checkWaiting(id, m, entry)
  })

  function readAloud(thread: string, on = true): Promise<ReadAloud> {
    const m = members.get(thread)
    if (!m) return Promise.resolve(null)
    const turn = m.turn ?? ""
    return new Promise((answer) => {
      let done = false
      const resolve = (value: ReadAloud) => {
        if (done) return
        done = true
        clear()
        answer(value)
      }
      const clear = host.after(readAloudDeadline, () => resolve(null))
      m.chain = m.chain.then(async () => {
        if (done) return
        if (m.helloed && m.quiet) return resolve("quiet")
        if (!connected || stopped || !m.helloed || members.get(thread) !== m) return resolve(null)
        const response = await post("/event", { op: "notify", session: sessionOf(thread), turn, on, instance: instanceOf(thread), connection }, readAloudDeadline)
        if (!response?.ok) return resolve(null)
        try {
          const answer = JSON.parse(response.text)
          resolve(answer?.quiet === true ? "quiet" : typeof answer?.spoken === "boolean" ? answer.spoken : null)
        } catch {
          resolve(null)
        }
      })
    })
  }

  const ended = (thread: any, reason: string, answer: string) => {
    const m = thread?.id ? members.get(thread.id) : undefined
    if (!m) return
    stopWaiting(thread.id, m)
    m.unstarted = null
    m.status = "idle"
    const turn = m.turn
    m.turn = null
    if (!turn) return
    report(thread.id, async () => ({ op: "turnComplete", session: sessionOf(thread.id), reason, answer: answer.slice(0, answerLimit) }))
  }
  bb.on("thread.idle", ({ thread, lastAssistantText }) => ended(thread, "complete", typeof lastAssistantText === "string" ? lastAssistantText : ""))
  bb.on("thread.failed", ({ thread }) => ended(thread, "error", ""))

  void connect()
  const labels = (threads: string[]) => Object.fromEntries(threads.map((thread) => [thread, names.get(thread) ?? null]))
  async function command(thread: string, on: boolean): Promise<string> {
    const running = (members.get(thread)?.turn ?? null) !== null
    return commandAnswer(appNameOf(config), !on, await readAloud(thread, on), running)
  }

  return { stop: () => stop(), window, readAloud, command, labels, settings }
}
