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
export type WindowReport = { window: string; focused: boolean; thread: string | null }
export type Pane = { threadId: string | null; isFocused: boolean }
export type Bb = {
  listThreads: () => Promise<Thread[]>
  history: (thread: string) => Promise<string[]>
  interaction: (thread: string, id: string) => Promise<string | null>
  on: (event: string, handler: (payload: any) => void) => void
}
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
}

const features = ["promptDigest", "readiness", "shown", "notify", "label"]
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

export function readAloudReply(app: string, answer: ReadAloud): string {
  if (answer === true) return `${app} will report your final reply when this turn ends. Say so in one short sentence and continue.`
  if (answer === false) return `Reply updates are off in ${app}. Tell the user to turn on Reply updates in ${app}’s Agent settings and ask again. Nothing will be reported.`
  if (answer === "quiet") return `This conversation is disconnected from ${app}. Tell the user to reconnect it in ${app}’s Agent settings. Nothing will be reported.`
  return `${app} didn’t confirm the request, so a spoken reply can’t be promised. Tell the user.`
}

export function shownThread(route: string | null, panes: Pane[] | null): string | null {
  if (!route) return null
  const focused = panes?.find((pane) => pane.isFocused)
  return !focused || focused.threadId === route ? route : null
}

type Checked<T> = { value: T } | { issues: { message: string }[] }
type Schema<T> = { readonly "~standard": { readonly version: 1; readonly vendor: string; readonly validate: (value: unknown) => Checked<T> } }

function schema<T>(accepts: (value: unknown) => value is T, message: string): Schema<T> {
  return { "~standard": { version: 1, vendor: "keyscribe", validate: (value) => accepts(value) ? { value } : { issues: [{ message }] } } }
}

function isWindowReport(value: unknown): value is WindowReport {
  if (!value || typeof value !== "object") return false
  const report = value as Record<string, unknown>
  return typeof report.window === "string" && report.window.length > 0 && report.window.length <= 64 && typeof report.focused === "boolean"
    && (report.thread === null || (typeof report.thread === "string" && report.thread.length <= 128))
}

function isThreadKeys(value: unknown): value is { keys: string[] } {
  if (!value || typeof value !== "object") return false
  const keys = (value as Record<string, unknown>).keys
  return Array.isArray(keys) && keys.length <= 1000 && keys.every((key) => typeof key === "string" && key.length <= 128)
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
  readAloud: (thread: string) => Promise<ReadAloud>
  labels: (threads: string[]) => Record<string, string | null>
  settings: Promise<{ appName?: string; instance?: string } | null>
} {
  const connection = "bb-" + host.random()
  const members = new Map<string, Member>()
  const names = new Map<string, string>()
  const queued = new Map<string, { thread: string; text: string }>()
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
  const windows = new Map<string, { thread: string | null; focused: boolean; focusedAt: number; seenAt: number }>()
  let focusings = 0
  let turnCount = 0
  let wanted: string | null = null
  let told: string | null | undefined
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
      waiting: null, unsaid: false, resay: false,
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
        if (failures === 0) host.log("the app is not running; waiting for it")
        return schedule()
      }
      token = (await host.read(config.tokenPath)).trim()
      if (ready.launch !== launch) for (const m of members.values()) m.helloed = false
      launch = ready.launch
      if (!listed) {
        for (const thread of await bb.listThreads()) member(thread.id, thread.status)
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
    if (next !== undefined) return next === null ? undefined : promptDigest(next)
    try {
      const waiting = new Set([...queued.values()].filter((q) => q.thread === thread).map((q) => q.text))
      const newest = (await bb.history(thread)).find((entry) => !waiting.has(entry))
      return newest === undefined ? undefined : promptDigest(newest)
    } catch {
      return undefined
    }
  }

  function front(): string | null {
    const now = host.now()
    for (const [id, w] of windows) if (now - w.seenAt > windowSilence) windows.delete(id)
    const fresh = [...windows.values()]
    const focusedNow = fresh.filter((w) => w.focused)
    const pool = (focusedNow.length ? focusedNow : fresh).filter((w) => w.focusedAt > 0)
    let best: { thread: string | null; focusedAt: number } | null = null
    for (const w of pool) if (!best || w.focusedAt > best.focusedAt) best = w
    return best?.thread ?? null
  }

  function reachable(thread: string | null | undefined): thread is string {
    const m = thread ? members.get(thread) : undefined
    return !!m && m.helloed && !m.quiet
  }

  function tell() {
    if (!connected || stopped || telling || !config) return
    const target = reachable(wanted) ? wanted : null
    if (told !== undefined && told === target) return
    const via = target ?? (reachable(told) ? told : [...members.keys()].find(reachable))
    if (!via) {
      told = target
      return
    }
    telling = true
    retelling?.()
    retelling = null
    void post("/event", { op: "shown", session: sessionOf(via), on: target !== null, instance: instanceOf(via), connection }, eventDeadline).then((response) => {
      telling = false
      if (response?.ok) {
        told = target
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
    wanted = front()
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

  function arrived(thread: any) {
    if (!thread?.id || members.has(thread.id)) return
    member(thread.id, thread.status)
    changed()
  }

  bb.on("thread.created", ({ thread }) => arrived(thread))
  bb.on("thread.unarchived", ({ thread }) => arrived(thread))
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
    if (added) return changed()
    report(thread.id, async () => {
      const prompt = await startedPrompt(thread.id, next)
      return prompt === undefined ? { op: "turnStarted", session: sessionOf(thread.id), turn } : { op: "turnStarted", session: sessionOf(thread.id), turn, prompt }
    })
  })
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

  function readAloud(thread: string): Promise<ReadAloud> {
    const m = members.get(thread)
    if (!m || (m.turn === null && busy.has(m.status))) return Promise.resolve(null)
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
        const response = await post("/event", { op: "notify", session: sessionOf(thread), turn, on: true, instance: instanceOf(thread), connection }, readAloudDeadline)
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
  return { stop: () => stop(), window, readAloud, labels, settings }
}
