export type Response = { status: number; ok: boolean; text: string }
export type Exchange = { response: Promise<Response>; cancel: () => void }
export type Host = {
  pid: number
  now: () => number
  read: (path: string) => Promise<string>
  readBase64: (path: string) => Promise<string>
  after: (ms: number, fn: () => void) => () => void
  post: (socketPath: string, path: string, body: string, token: string) => Exchange
  random: () => string
  log: (message: string) => void
  watch?: (folder: string, changed: () => void, broken: () => void) => (() => void) | null
}
export type Summary = { id: number; title?: string; named: boolean; cwd: string; busy: boolean }
export type Image = { data: string; mimeType: string }
export type Ultimate = {
  version: string
  home: string
  list: () => Summary[]
  unavailable?: (id: number) => string
  submit: (id: number, text: string, images: Image[], requestId: string) => Promise<number>
}
export type Waiting = { kind?: string; title?: string; detail?: string }
export type ReadAloud = boolean | "quiet" | null
export type PageReport = {
  page: string
  seq?: number
  focused: boolean
  conversation: number | null
  draft: boolean
  newConversation?: boolean
  parent?: number
  pageConversation?: number | null
  problem?: string
}
export type ComposeAsk = { id: string; kind?: "start"; conversation: number; text: string }
export type StartResult = { sent: boolean; withDraft?: boolean; reason?: string; detail?: string }
export type Config = {
  protocol: number
  socketPath: string
  tokenPath: string
  readyPath: string
  installation: string
  setup: string
  version?: string
  appName?: string
  plugin?: string
}

type Turn = { id: string; input?: { entry: number; from?: string; prompt?: string } }
type Member = {
  helloed: boolean
  greeting: boolean
  resay: boolean
  quiet: boolean
  unsaid: boolean
  busy: boolean
  title?: string
  label?: string
  turn: Turn | null
  answer: string
  answered: boolean
  failed: string | null
  waiting: Waiting | null
  prompts: number
  chain: Promise<void>
}
type Delivery = {
  id: string
  conversation: number
  prompt: string
  steer: boolean
  submission: number | null
  entry: number | null
  matched: boolean
  state: "holding" | "handed" | "seen" | "refused"
  reason?: string
  turn?: string
  handedAt?: number
  seenAt?: number
  withDraft?: boolean
}
type Placed = { conversation: number; turn: string; started: boolean }
type Join = { ask: ComposeAsk; page: string; started: boolean; stop: () => void; draft: (text: string | null) => void; sent?: (ok: boolean) => void }
type PendingStart = { ask: ComposeAsk; page: string; picked: boolean; stop: () => void; finish: (result: StartResult) => void }
type Command = {
  op?: unknown; id?: unknown; expectedSession?: unknown; text?: unknown; expiresAt?: unknown; images?: unknown; merge?: unknown; request?: unknown
  expectedPrompts?: unknown
}

const features = ["readiness", "notify", "images", "check", "steer", "merge", "promptDigest", "shown", "label", "start"]
const labelLimit = 200
const answerLimit = 8 * 1024
const eventDeadline = 2000
const pollDeadline = 310000
const backoff = [10000, 30000, 60000]
const greetingLimit = 8
const deliveryLimit = 64
const recentLimit = 64
const pageSilence = 15000
const pageSweep = 5000
const shownRetry = 5000
const readAloudDeadline = 4000
const composeStart = 1000
const composeDeadline = 6000
const composeWait = 25000
const waitingTitleLimit = 300
const waitingDetailLimit = 1000
const maxImages = 8
const userInput = "pi.user"

export function senderOf(kind: string): string | null | undefined {
  if (kind === userInput) return undefined
  if (kind.startsWith("board.")) return "agent"
  if (kind === "automations.fired") return "schedule"
  return null
}

export function promptDigest(text: string): string {
  const plain = (text.startsWith("​") ? text.slice(1) : text).trim()
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(plain)) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, "0")
}

export function runsAsCommand(text: string): boolean {
  return /^[/!]/.test(text.trimStart())
}

export function joined(draft: string, text: string): string {
  return draft + (/\s$/.test(draft) ? "" : " ") + text
}

export function appNameOf(config: { appName?: string } | null | undefined): string {
  return config?.appName?.trim() || "the voice app"
}

export function readAloudToolName(plugin: string): string {
  return `${plugin.replace(/[^A-Za-z0-9]+/g, "_")}_tell_me_when_done`
}

export function readAloudReply(app: string, answer: ReadAloud): string {
  if (answer === true) return `${app} will report your final reply when this turn ends. Say so in one short sentence and continue.`
  if (answer === false) return `Read Agent Replies Aloud is off in ${app}. Tell the user to turn on Read Agent Replies Aloud in ${app}’s Agent settings and ask again. Nothing will be reported.`
  if (answer === "quiet") return `This conversation is disconnected from ${app}. Tell the user to reconnect it in ${app}’s Agent settings. Nothing will be reported.`
  return `${app} didn’t confirm the request, so the reply may not be reported. Tell the user.`
}

export function commandAnswer(app: string, cancelling: boolean, answer: ReadAloud, running: boolean): string {
  if (answer === "quiet") return `This conversation is disconnected from ${app}. Reconnect it in ${app}’s Agent settings.`
  if (answer === null) return cancelling ? `${app} didn’t confirm the cancel.` : `${app} didn’t confirm the request, so you may not get this reply.`
  if (cancelling) return `${app} won’t report this reply.`
  if (answer === false) return `Read Agent Replies Aloud is off. Turn on Read Agent Replies Aloud in ${app}’s Agent settings.`
  return running ? `${app} will report the result of this work.` : `${app} will report your next reply.`
}

export function waitingFor(text: string, questions: unknown): Waiting {
  const first: any = Array.isArray(questions) ? questions[0] : undefined
  const asked = typeof first?.text === "string" && first.text.trim() ? first.text : text
  const title = asked.trim().slice(0, waitingTitleLimit)
  const options: string[] = Array.isArray(first?.options)
    ? first.options.map((option: any) => option?.label).filter((label: unknown): label is string => typeof label === "string" && label.trim() !== "")
    : []
  const found: Waiting = { kind: options.length ? "select" : "input" }
  if (title) found.title = title
  if (options.length) found.detail = options.join(", ").slice(0, waitingDetailLimit)
  return found
}

function key(conversation: number, instance: string): string {
  return String(conversation).replace(/%/g, "%25").replace(/@/g, "%40") + "@" + instance
}

function failure(error: unknown): string {
  const said = error instanceof Error ? error.message : String(error)
  return said.trim().slice(0, 500) || "Ultimate refused the message."
}

function remember<K, V>(map: Map<K, V>, key: K, value: V) {
  map.delete(key)
  map.set(key, value)
  for (const old of map.keys()) {
    if (map.size <= recentLimit) break
    map.delete(old)
  }
}

export type TypingTarget = { kind: "conversation"; id: number } | { kind: "newSideChat"; parent: number } | { kind: "none" }

export function typingTarget(
  editors: Array<{ id: number; active: boolean; sideMode?: boolean }>, blocked: boolean, elsewhere = false
): TypingTarget {
  if (blocked || elsewhere) return { kind: "none" }
  const active = editors.filter(editor => editor.active)
  const chosen = active.length === 1 ? active[0] : editors.length === 1 ? editors[0] : undefined
  if (!chosen) return { kind: "none" }
  return chosen.sideMode ? { kind: "newSideChat", parent: chosen.id } : { kind: "conversation", id: chosen.id }
}

const textInputs = new Set(["text", "search", "email", "url", "tel", "password", "number"])

export function typesText(element: {
  tagName: string; type?: string; role?: string | null; isContentEditable?: boolean; disabled?: boolean; readOnly?: boolean
} | null): boolean {
  if (!element || element.disabled || element.readOnly) return false
  if (element.tagName === "TEXTAREA") return true
  if (element.tagName === "INPUT") return textInputs.has((element.type || "text").toLowerCase())
  return element.isContentEditable === true || element.role === "textbox"
}

export function composerProblem(state: { blocked: boolean; elsewhere: boolean; editors: number; home: boolean }): string {
  if (state.blocked) return "A dialog covers Ultimate’s composer."
  if (state.elsewhere) return "The box with focus in Ultimate is not a conversation’s message box. "
    + (state.editors > 0 ? "Click in a message box, or say the conversation’s name." : "Open a conversation, or say its name.")
  if (state.editors > 1) return "Ultimate has several writable composers. Click in the one to use."
  if (!state.home) return "What Ultimate shows has no message box. Open a conversation, or say its name."
  return "Ultimate’s composer is not ready."
}

export function typingConversation(editors: Array<{ id: number; active: boolean; sideMode?: boolean }>, blocked: boolean): number | null {
  const target = typingTarget(editors, blocked)
  return target.kind === "conversation" ? target.id : null
}

export const traceLimit = 4000

export function automatedBrowser(browser: { webdriver?: boolean; userAgent: string }): boolean {
  return browser.webdriver === true || /HeadlessChrome\//.test(browser.userAgent)
}

export function namedByUser(title: string | undefined, generatedTitle: string | undefined): boolean {
  return title !== undefined && title !== generatedTitle
}

export function keyscribe(ultimate: Ultimate, host: Host, loadConfig: () => Promise<Config | null>) {
  const connection = "ultimate-" + host.random()
  const members = new Map<number, Member>()
  const deliveries = new Map<string, Delivery>()
  const placements = new Map<number, number>()
  const inputs = new Map<number, Placed>()
  const pages = new Map<string, {
    conversation: number | null; draft: boolean; newConversation: boolean; parent?: number; pageConversation?: string
    focused: boolean; focusedAt: number; seenAt: number; problem?: string; seq?: number
  }>()
  const joins = new Map<string, Join>()
  const starts = new Map<string, PendingStart>()
  const waiters = new Map<string, (ask: ComposeAsk | null) => void>()
  let config: Config | null = null
  let token = ""
  let launch: string | null = null
  let connected = false
  let connecting = false
  let stopped = false
  let failures = 0
  let retry: (() => void) | null = null
  let unwatch: (() => void) | null = null
  let watchBroken = false
  let recheck = false
  let pollAcks = false
  let acked: Array<{ request: string; instance: string }> = []
  let polling: { cancel: () => void } | null = null
  let focusings = 0
  let turns = 0
  let wanted: number | null = null
  let wantedDraft = false
  let wantedNew = false
  let wantedPage: string | undefined
  let wantedProblem: string | undefined
  let told: number | null | undefined
  let toldDraft = false
  let toldNew = false
  let toldPage: string | undefined
  let toldProblem: string | undefined
  let telling = false
  let retelling: (() => void) | null = null
  let sweeping: (() => void) | null = null

  const instanceOf = (id: number) => `${connection}/${id}`
  const sessionOf = (id: number) => key(id, ultimate.home)
  const memberOf = (session: unknown) => [...members.keys()].find((id) => sessionOf(id) === session)
  const newTurn = () => `${connection}.${++turns}`

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
    if (stopped || connected) return
    if (connecting) {
      recheck = true
      return
    }
    retry?.()
    retry = null
    void connect()
  }

  function watchReady(readyPath: string) {
    if (unwatch || watchBroken || !host.watch) return
    unwatch = host.watch(readyPath.slice(0, readyPath.lastIndexOf("/")), wake, () => {
      unwatch = null
      watchBroken = true
      if (!connected && !connecting) schedule()
    })
    if (!unwatch) watchBroken = true
  }

  function fail() {
    if (connected) host.log("lost the connection to the app; trying again later")
    connected = false
    acked = []
    polling?.cancel()
    polling = null
    schedule()
  }

  function stop(reason?: string) {
    if (stopped) return
    if (reason) host.log(reason)
    stopped = true
    acked = []
    connected = false
    polling?.cancel()
    polling = null
    retry?.()
    retry = null
    unwatch?.()
    unwatch = null
    sweeping?.()
    sweeping = null
    retelling?.()
    retelling = null
    for (const join of [...joins.values()]) finishJoin(join.ask.id, false)
    for (const pending of [...starts.values()]) finishStart(pending.ask.id, { sent: false, reason: "gone" })
    for (const waiter of waiters.values()) waiter(null)
    waiters.clear()
  }

  async function connect() {
    if (stopped || connecting || connected) return
    connecting = true
    let proceeding = false
    try {
      if (!config) {
        config = await loadConfig()
        if (stopped) return
        if (!config) return stop("its settings file is missing; install it again from the app's settings")
      }
      watchReady(config.readyPath)
      recheck = false
      let ready: any
      try {
        ready = JSON.parse(await host.read(config.readyPath))
      } catch {
        ready = null
      }
      if (stopped) return
      if (!ready || typeof ready.launch !== "string") {
        if (failures === 0) host.log("the app is not running; waiting for it")
        if (unwatch) {
          failures += 1
          return
        }
        return schedule()
      }
      if (ready.protocol !== config.protocol) return stop("the app speaks another protocol; update the extension from the app's settings")
      token = (await host.read(config.tokenPath)).trim()
      if (ready.launch !== launch) for (const m of members.values()) m.helloed = false
      launch = ready.launch
      proceeding = true
    } catch {
      return schedule()
    } finally {
      connecting = false
      if (recheck && !proceeding && !stopped) {
        recheck = false
        retry?.()
        retry = null
        void connect()
      }
    }
    if (stopped) return
    connected = true
    host.log("connected to the app")
    await greetAll()
  }

  async function greetAll() {
    const due = [...members.keys()].filter((id) => {
      const m = members.get(id)!
      return (!m.helloed || m.resay) && !m.greeting
    })
    const results: Array<"ok" | "failed" | "gone" | number> = []
    const cwds = new Map(ultimate.list().map((s) => [s.id, s.cwd]))
    let next = 0
    const worker = async () => {
      while (next < due.length && !stopped) results.push(await greet(due[next++], cwds))
    }
    await Promise.all(Array.from({ length: Math.min(greetingLimit, due.length) }, worker))
    if (!connected || stopped) return
    const refused = results.find((r) => typeof r === "number")
    if (refused !== undefined) return stop(`the app refused this extension (${refused}); install it again from the app's settings`)
    if (results.some((r) => r === "failed")) return fail()
    failures = 0
    told = undefined
    tell()
    repoll()
  }

  async function greet(id: number, cwds: Map<number, string>): Promise<"ok" | "failed" | "gone" | number> {
    const m = members.get(id)
    if (!m || !config) return "gone"
    m.greeting = true
    m.resay = false
    const greetedPrompts = m.prompts
    const greetedTitle = m.title
    const greetedWaiting = JSON.stringify(m.waiting ?? null)
    const response = await post("/event", {
      op: "hello", protocol: config.protocol, agent: "ultimate", agentVersion: ultimate.version, codeVersion: config.version,
      instance: instanceOf(id), session: sessionOf(id), pid: host.pid, features, idle: !m.busy, gap: true, connection,
      installation: config.installation, cwd: cwds.get(id), prompts: greetedPrompts,
      ...(greetedTitle ? { title: greetedTitle } : {}),
      ...(m.waiting ? { waiting: m.waiting } : {}),
      ...(m.turn ? { turn: m.turn.id } : {}),
    }, eventDeadline)
    m.greeting = false
    if (members.get(id) !== m) return "gone"
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
      const answer = JSON.parse(response.text)
      m.quiet = answer?.quiet === true
      pollAcks = answer?.acks === true
    } catch {
      m.quiet = false
    }
    m.helloed = true
    if (!m.quiet) m.unsaid = false
    if (!m.quiet && m.prompts > greetedPrompts) {
      const prompts = m.prompts
      report(id, () => ({ op: "typed", session: sessionOf(id), prompts }))
    }
    if (!m.quiet && m.title !== greetedTitle) {
      const text = m.title ?? ""
      report(id, () => ({ op: "title", session: sessionOf(id), text }))
    }
    if (!m.quiet && JSON.stringify(m.waiting ?? null) !== greetedWaiting) {
      const now = m.waiting
      report(id, () => (now ? { op: "waiting", session: sessionOf(id), waiting: now } : { op: "waiting", session: sessionOf(id) }), true)
    }
    if (!m.quiet && m.turn?.input) {
      const turn = m.turn
      report(id, () => (m.turn === turn && turn.input ? { op: "turnStarted", session: sessionOf(id), turn: turn.id, prompt: turn.input.prompt } : null))
    }
    return "ok"
  }

  function repoll() {
    polling?.cancel()
    polling = null
    if (!connected || stopped || !config) return
    const list = [...members.entries()].filter(([, m]) => m.helloed).map(([id]) => ({ session: sessionOf(id), instance: instanceOf(id) }))
    if (!list.length) return
    let cancelled = false
    const acks = acked.slice()
    const exchange = host.post(
      config.socketPath, "/poll", JSON.stringify({ members: list, connection, wait: pollDeadline / 1000, ...(acks.length ? { acks } : {}) }), token)
    const clear = host.after(pollDeadline, () => exchange.cancel())
    const current = { cancel: () => { cancelled = true; clear(); exchange.cancel() } }
    polling = current
    exchange.response.then((response) => response, () => null).then((response) => {
      clear()
      if (cancelled || polling !== current) return
      polling = null
      if (response) acked.splice(0, acks.length)
      void commanded(response)
    })
  }

  async function commanded(response: Response | null) {
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
    const commands: Command[] = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.commands) ? parsed.commands : []
    if (commands.some((c) => c && c.op === "retire")) return stop("the app retired this extension")
    const readmitted: number[] = []
    const ids = new Map<unknown, number>([...members.keys()].map((id) => [sessionOf(id), id]))
    for (const command of commands) {
      const id = ids.get(command?.expectedSession)
      if (id === undefined || typeof command.id !== "string") continue
      const m = members.get(id)!
      if (command.op === "quiet" || command.op === "admit") {
        m.quiet = command.op === "quiet"
        told = undefined
        if (command.op === "admit" && m.unsaid) readmitted.push(id)
      }
      if (command.op === "status" && typeof command.text === "string") m.label = command.text.slice(0, labelLimit)
      if (pollAcks) acked.push({ request: command.id, instance: instanceOf(id) })
      else reply(id, { op: "ack", request: command.id })
      if (command.op === "submit") void submit(id, command)
      else if (command.op === "start") void startFromPage(id, command)
      else if (command.op === "check") check(id, command)
      else if (command.op === "focus") reply(id, { op: "refused", request: command.id, reason: "unsupported" })
    }
    const unknown: string[] = Array.isArray(parsed?.unknown) ? parsed.unknown : []
    for (const [id, m] of members) if (unknown.includes(instanceOf(id)) || readmitted.includes(id)) m.helloed = false
    if (unknown.length || readmitted.length) return greetAll()
    tell()
    repoll()
  }

  function reply(id: number, body: object) {
    void post("/event", { ...body, instance: instanceOf(id), connection }, eventDeadline)
  }

  function report(id: number, body: () => object | null, state = false) {
    const m = members.get(id)
    if (!m) return
    const rehello = () => {
      if (stopped || members.get(id) !== m) return
      m.resay = true
      m.chain = m.chain.then(() => {
        if (connected && !stopped && m.resay) void greetAll()
      })
    }
    m.chain = m.chain.then(async () => {
      if (state && m.quiet) m.unsaid = true
      if (stopped || m.quiet || !m.helloed) return
      if (!connected) return state ? rehello() : undefined
      const event = body()
      if (!event || stopped || !m.helloed || m.quiet) return
      const response = await post("/event", { ...event, instance: instanceOf(id), connection }, eventDeadline)
      if (response?.status === 409 && members.get(id) === m) {
        m.helloed = false
        if (connected) void greetAll()
      } else if (state && !response?.ok) rehello()
    })
  }

  function refuse(id: number, delivery: Delivery, reason: string, detail?: string) {
    delivery.state = "refused"
    delivery.reason = reason
    reply(id, { op: "refused", request: delivery.id, reason, ...(detail ? { detail } : {}) })
  }

  function receipt(id: number, delivery: Delivery) {
    reply(id, {
      op: "submitted", request: delivery.id, turn: delivery.turn ?? "", handedAt: delivery.handedAt, seenAt: delivery.seenAt,
      ...(delivery.withDraft ? { withDraft: true } : {}),
    })
  }

  async function attached(paths: unknown): Promise<Image[]> {
    if (!Array.isArray(paths)) return []
    const read = await Promise.all(paths.slice(0, maxImages).map(async (path) => {
      if (typeof path !== "string" || !path.toLowerCase().endsWith(".png")) return null
      try {
        return { data: await host.readBase64(path), mimeType: "image/png" }
      } catch {
        return null
      }
    }))
    return read.filter((image): image is Image => image !== null)
  }

  function held(id: number, command: Command): string | null {
    const m = members.get(id)
    if (!m || !m.helloed || memberOf(command.expectedSession) !== id) return "sessionChanged"
    if (m.quiet) return "disconnected"
    if (!(host.now() < (typeof command.expiresAt === "number" ? command.expiresAt : 0))) return "expired"
    if (typeof command.expectedPrompts === "number" && command.expectedPrompts !== m.prompts) return "typedSince"
    return null
  }

  async function submit(id: number, command: Command) {
    const text = typeof command.text === "string" ? command.text : ""
    const delivery: Delivery = { id: command.id as string, conversation: id, prompt: promptDigest(text), steer: false, submission: null, entry: null, matched: false, state: "holding" }
    remember(deliveries, delivery.id, delivery)
    const images = await attached(command.images)
    const first = held(id, command)
    if (first) return refuse(id, delivery, first)
    let send = text
    let joining = false
    if (command.merge === true && !images.length && !runsAsCommand(text)) {
      const page = shownPage(id)
      const draft = page ? await compose(page, { id: delivery.id, conversation: id, text }) : null
      if (draft !== null && draft.trim()) {
        if (runsAsCommand(draft)) {
          finishJoin(delivery.id, false)
          return refuse(id, delivery, "draft")
        }
        send = joined(draft, text)
        delivery.withDraft = true
        joining = true
      } else finishJoin(delivery.id, false)
    }
    const again = held(id, command)
    if (again) {
      finishJoin(delivery.id, false)
      return refuse(id, delivery, again)
    }
    delivery.steer = members.get(id)!.busy
    delivery.state = "handed"
    delivery.handedAt = host.now()
    let submission: number
    try {
      submission = await ultimate.submit(id, send, images, delivery.id)
    } catch (error) {
      finishJoin(delivery.id, false)
      return refuse(id, delivery, failure(error))
    }
    if (joining) finishJoin(delivery.id, true)
    delivery.submission = submission
    if (delivery.steer && delivery.state === "handed") {
      delivery.state = "seen"
      delivery.seenAt = host.now()
      receipt(id, delivery)
    }
    const entry = placements.get(submission)
    if (entry !== undefined) match(delivery, entry)
  }

  async function startFromPage(id: number, command: Command) {
    const requestId = command.id as string
    const text = typeof command.text === "string" ? command.text : ""
    if (!(host.now() < (typeof command.expiresAt === "number" ? command.expiresAt : 0))) {
      return reply(id, { op: "refused", request: requestId, reason: "expired" })
    }
    const shown = frontPage()
    if (!shown || !shown.newConversation || shown.parent === undefined) {
      return reply(id, { op: "refused", request: requestId, reason: "gone" })
    }
    if (members.get(shown.parent)?.quiet) {
      return reply(id, { op: "refused", request: requestId, reason: "disconnected" })
    }
    const result = await askStart(shown.page, { id: requestId, kind: "start", conversation: shown.parent, text })
    if (result.sent) {
      changed()
      return reply(id, { op: "submitted", request: requestId, turn: "", ...(result.withDraft ? { withDraft: true } : {}) })
    }
    reply(id, { op: "refused", request: requestId, reason: result.reason ?? "failed", ...(result.detail ? { detail: result.detail } : {}) })
  }

  function check(id: number, command: Command) {
    const request = typeof command.request === "string" ? command.request : ""
    const delivery = deliveries.get(request)
    const state = delivery
      ? { state: delivery.state, reason: delivery.reason, turn: delivery.turn, handedAt: delivery.handedAt, seenAt: delivery.seenAt, withDraft: delivery.withDraft }
      : { state: "unknown" }
    reply(id, { op: "checked", request, check: command.id, ...state })
  }

  function match(delivery: Delivery, entry: number) {
    if (delivery.matched || delivery.state === "refused") return
    delivery.entry = entry
    const seen = inputs.get(entry)
    if (!seen) return
    delivery.matched = true
    const id = delivery.conversation
    const turn = members.get(id)?.turn
    if (turn?.id === seen.turn && turn.input?.entry === entry) turn.input.prompt = delivery.prompt
    delivery.turn = seen.turn
    if (delivery.steer) {
      const prompt = delivery.prompt
      const request = delivery.id
      report(id, () => ({ op: "absorbed", session: sessionOf(id), turn: seen.turn, prompt, request }))
      return
    }
    if (delivery.state === "handed") {
      delivery.state = "seen"
      delivery.seenAt = host.now()
    }
    receipt(id, delivery)
  }

  function placed(submission: number, entry: number, requestId?: string) {
    remember(placements, submission, entry)
    const delivery = (requestId === undefined ? undefined : deliveries.get(requestId)) ?? [...deliveries.values()].find((d) => d.submission === submission)
    if (!delivery) return
    delivery.submission = submission
    match(delivery, entry)
  }

  function startTurn(id: number, m: Member, prompt?: string): Turn {
    m.busy = true
    if (m.turn) return m.turn
    const turn: Turn = { id: newTurn() }
    m.turn = turn
    m.answer = ""
    m.answered = false
    m.failed = null
    report(id, () => ({ op: "turnStarted", session: sessionOf(id), turn: turn.id, ...(prompt ? { prompt } : {}) }))
    return turn
  }

  function input(id: number, entry: number, kind: string, text: string) {
    if (!members.has(id)) changed()
    const m = members.get(id)
    if (!m) return
    if (m.turn && m.answered) endTurn(id, m)
    const started = m.turn === null
    const prompt = promptDigest(text)
    const turn = startTurn(id, m, prompt)
    const from = senderOf(kind)
    if (from === null) {
      if (!turn.input) turn.input = { entry, from: "other" }
    } else {
      turn.input = { entry, prompt, ...(from ? { from } : {}) }
    }
    remember(inputs, entry, { conversation: id, turn: turn.id, started })
    const delivery = [...deliveries.values()].find((d) => d.conversation === id && (d.entry === entry || (d.submission !== null && placements.get(d.submission) === entry)))
    if (delivery) return match(delivery, entry)
    if (kind !== userInput) return
    m.prompts += 1
    const prompts = m.prompts
    report(id, () => ({ op: "typed", session: sessionOf(id), prompts }))
  }

  function replied(id: number, text: string, stopReason: string | undefined) {
    const m = members.get(id)
    if (!m) return
    m.answered = false
    if (stopReason === "error" || stopReason === "aborted") {
      m.failed = stopReason
      m.answer = ""
      return
    }
    if (stopReason === "toolUse") return
    m.failed = null
    if (text.trim()) m.answer = text
    m.answered = m.answer !== ""
  }

  function endTurn(id: number, m: Member) {
    m.busy = false
    const turn = m.turn
    m.turn = null
    if (!turn) return
    const reason = m.failed === "aborted" ? "aborted" : m.failed === "error" ? "error" : "complete"
    const answer = reason === "complete" ? m.answer.slice(0, answerLimit) : ""
    m.answer = ""
    m.answered = false
    m.failed = null
    const after = turn.input ? { ...(turn.input.prompt ? { prompt: turn.input.prompt } : {}), ...(turn.input.from ? { from: turn.input.from } : {}) } : {}
    report(id, () => ({ op: "turnComplete", session: sessionOf(id), reason, answer, ...after }))
  }

  function changed() {
    if (stopped) return
    const seen = new Set<number>()
    let added = false
    for (const summary of ultimate.list()) {
      seen.add(summary.id)
      const title = summary.named ? summary.title : undefined
      const m = members.get(summary.id)
      if (!m) {
        members.set(summary.id, {
          helloed: false, greeting: false, resay: false, quiet: false, unsaid: false, busy: summary.busy, title,
          turn: summary.busy ? { id: newTurn() } : null, answer: "", answered: false, failed: null, waiting: null, prompts: 0, chain: Promise.resolve(),
        })
        added = true
        continue
      }
      if (title !== m.title) {
        m.title = title
        const id = summary.id
        report(id, () => ({ op: "title", session: sessionOf(id), text: title ?? "" }))
      }
      if (summary.busy && !m.busy) startTurn(summary.id, m)
      else if (!summary.busy && m.busy) endTurn(summary.id, m)
    }
    let removed = false
    for (const id of [...members.keys()]) {
      if (seen.has(id)) continue
      members.delete(id)
      removed = true
    }
    if (!connected) return
    if (added) return void greetAll()
    if (removed) {
      tell()
      repoll()
    }
  }

  function waiting(open: Map<number, Waiting>) {
    for (const [id, m] of members) {
      const now = open.get(id) ?? null
      if (JSON.stringify(now) === JSON.stringify(m.waiting)) continue
      m.waiting = now
      report(id, () => (now ? { op: "waiting", session: sessionOf(id), waiting: now } : { op: "waiting", session: sessionOf(id) }), true)
    }
  }

  function readAloud(id: number, on = true): Promise<ReadAloud> {
    const m = members.get(id)
    if (!m) return Promise.resolve(null)
    const turn = m.turn?.id ?? ""
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
        if (!connected || stopped || !m.helloed || members.get(id) !== m) return resolve(null)
        const response = await post("/event", { op: "notify", session: sessionOf(id), turn, on, instance: instanceOf(id), connection }, readAloudDeadline)
        if (!response?.ok) return resolve(null)
        try {
          const parsed = JSON.parse(response.text)
          resolve(parsed?.quiet === true ? "quiet" : typeof parsed?.spoken === "boolean" ? parsed.spoken : null)
        } catch {
          resolve(null)
        }
      })
    })
  }

  async function command(id: number, on: boolean): Promise<string> {
    const running = (members.get(id)?.turn ?? null) !== null
    return commandAnswer(appNameOf(config), !on, await readAloud(id, on), running)
  }

  function frontPage(): {
    page: string; conversation: number | null; draft: boolean; newConversation: boolean; parent?: number; pageConversation?: string; problem?: string
  } | null {
    const now = host.now()
    for (const [page, p] of pages) if (now - p.seenAt > pageSilence) pages.delete(page)
    let best: {
      page: string; conversation: number | null; draft: boolean; newConversation: boolean; parent?: number; pageConversation?: string
      focusedAt: number; problem?: string
    } | null = null
    for (const [page, p] of pages) if (p.focused && p.focusedAt > 0 && (!best || p.focusedAt > best.focusedAt)) best = { page, ...p }
    return best
  }

  function shownPage(id: number): string | null {
    const front = frontPage()
    return front && front.conversation === id ? front.page : null
  }

  function reachable(id: number | null | undefined): id is number {
    const m = id === null || id === undefined ? undefined : members.get(id)
    return !!m && m.helloed && !m.quiet
  }

  function tell() {
    if (!connected || stopped || telling || !config) return
    const target = !wantedProblem && !wantedNew && reachable(wanted) ? wanted : null
    const newConversation = !wantedProblem && wantedNew
    const draft = (target !== null || newConversation) && wantedDraft
    const problem = !wantedNew && wanted !== null && !reachable(wanted)
      ? ultimate.unavailable?.(wanted) ?? `Ultimate shows conversation ${wanted}, but it is not listed.` : wantedProblem
    const pageConversation = target !== null || newConversation || problem ? wantedPage : undefined
    if (told !== undefined && told === target && toldDraft === draft && toldNew === newConversation
      && toldPage === pageConversation && toldProblem === problem) return
    const via = target ?? (reachable(told) ? told : [...members.keys()].find(reachable))
    if (via === undefined || via === null) {
      told = target
      toldDraft = draft
      toldNew = newConversation
      toldPage = pageConversation
      toldProblem = problem
      return
    }
    telling = true
    retelling?.()
    retelling = null
    const body = {
      op: "shown",
      ...(problem ? { problem } : {}),
      ...(newConversation ? { newConversation: true } : {}),
      ...(pageConversation ? { pageConversation } : {}),
      session: sessionOf(via), on: target !== null, draft, instance: instanceOf(via), connection,
    }
    void post("/event", body, eventDeadline).then((response) => {
      telling = false
      if (response?.ok) {
        told = target
        toldDraft = draft
        toldNew = newConversation
        toldPage = pageConversation
        toldProblem = problem
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
    const shown = frontPage()
    wanted = shown?.conversation ?? null
    wantedDraft = shown?.draft ?? false
    wantedNew = shown?.newConversation ?? false
    wantedPage = shown?.pageConversation
    wantedProblem = shown?.problem
    tell()
    if (pages.size && !sweeping && !stopped) {
      sweeping = host.after(pageSweep, () => {
        sweeping = null
        settleFront()
      })
    }
  }

  function page(report: PageReport) {
    if (stopped || typeof report?.page !== "string") return
    const known = pages.get(report.page)
    if (typeof report.seq === "number" && known?.seq !== undefined && report.seq < known.seq) return
    if (typeof report.conversation === "number" && !members.has(report.conversation)) changed()
    const focused = report.focused === true
    const conversation = typeof report.conversation === "number" ? report.conversation : null
    const draft = report.draft === true
    const newConversation = report.newConversation === true
    const parent = typeof report.parent === "number" ? report.parent : undefined
    const pageConversation = typeof report.pageConversation === "number" ? String(report.pageConversation) : undefined
    const stateChanged = !known || !known.focused || known.conversation !== conversation || known.draft !== draft
      || known.newConversation !== newConversation || known.parent !== parent || known.pageConversation !== pageConversation
      || known.problem !== report.problem
    pages.set(report.page, {
      conversation,
      draft,
      newConversation,
      parent,
      pageConversation,
      focused,
      focusedAt: !focused ? 0 : stateChanged ? ++focusings : known.focusedAt,
      seenAt: host.now(),
      problem: report.problem,
      seq: typeof report.seq === "number" ? report.seq : known?.seq,
    })
    settleFront()
  }

  function askStart(page: string, ask: ComposeAsk): Promise<StartResult> {
    return new Promise((resolve) => {
      const pending: PendingStart = {
        ask, page, picked: false, stop: () => {},
        finish: (result) => { pending.finish = () => {}; resolve(result) },
      }
      pending.stop = host.after(composeDeadline, () => finishStart(ask.id, { sent: false, reason: "gone" }))
      starts.set(ask.id, pending)
      const waiter = waiters.get(page)
      if (waiter) {
        waiters.delete(page)
        pending.picked = true
        waiter(ask)
      }
    })
  }

  function finishStart(id: string, result: StartResult) {
    const pending = starts.get(id)
    if (!pending) return
    starts.delete(id)
    pending.stop()
    pending.finish(result)
  }

  function started(id: string, page: string, result: StartResult): boolean {
    const pending = starts.get(id)
    if (!pending || pending.page !== page) return false
    finishStart(id, result)
    return true
  }

  function compose(page: string, ask: ComposeAsk): Promise<string | null> {
    return new Promise((resolve) => {
      const join: Join = { ask, page, started: false, stop: () => {}, draft: (text) => { join.draft = () => {}; resolve(text) } }
      join.stop = host.after(composeStart, () => finishJoin(ask.id, false))
      joins.set(ask.id, join)
      const waiter = waiters.get(page)
      if (waiter) {
        waiters.delete(page)
        waiter(ask)
      }
    })
  }

  function finishJoin(id: string, sent: boolean) {
    const join = joins.get(id)
    if (!join) return
    joins.delete(id)
    join.stop()
    join.draft(null)
    join.sent?.(sent)
  }

  function nextCompose(page: string): Promise<ComposeAsk | null> {
    if (stopped) return Promise.resolve(null)
    for (const join of joins.values()) if (join.page === page && !join.started) return Promise.resolve(join.ask)
    for (const pending of starts.values()) if (pending.page === page && !pending.picked) {
      pending.picked = true
      return Promise.resolve(pending.ask)
    }
    waiters.get(page)?.(null)
    return new Promise((resolve) => {
      const clear = host.after(composeWait, () => {
        if (waiters.get(page) === answer) waiters.delete(page)
        resolve(null)
      })
      const answer = (ask: ComposeAsk | null) => {
        clear()
        resolve(ask)
      }
      waiters.set(page, answer)
    })
  }

  function composed(id: string, page: string, draft: string): Promise<boolean> {
    const join = joins.get(id)
    if (!join || join.started || join.page !== page) return Promise.resolve(false)
    join.started = true
    join.stop()
    join.stop = host.after(composeDeadline, () => finishJoin(id, false))
    return new Promise((resolve) => {
      join.sent = resolve
      join.draft(draft)
    })
  }

  void connect()
  changed()

  return {
    stop: () => stop(),
    wake,
    changed,
    placed,
    input,
    replied,
    waiting,
    page,
    nextCompose,
    composed,
    started,
    readAloud,
    command,
    label: (id: number) => (connected && reachable(id) ? members.get(id)?.label ?? null : null),
    get config() { return config },
  }
}
