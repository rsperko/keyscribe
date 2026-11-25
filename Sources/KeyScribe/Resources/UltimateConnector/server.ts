import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context'
import { defineExtension, defineTool } from '@earendil-works/pi-durable'
import type { CommitPublication, ConversationId, EntryRecord } from '@earendil-works/pi-durable'
import { obj } from '@earendil-works/pi-schema'
import { randomBytes } from 'node:crypto'
import { appendFileSync, readFileSync, realpathSync, watch } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { request } from 'node:http'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appNameOf, keyscribe, namedByUser, readAloudReply, readAloudToolName, traceLimit, waitingFor } from './keyscribe.ts'
import type { Config, Exchange, Image, PageReport, Response, Summary, Waiting } from './keyscribe.ts'

const here = dirname(fileURLToPath(import.meta.url))
const name = basename(here)
const responseLimit = 512 * 1024
const listSettles = 1000
const root = 1
const standing = 'agent'
const roles = new Set(['coordinator', 'side-chat'])
const freshFor = 30_000
const freshLimit = 64
const userInputEvent = {
  name: 'user.input',
  kind: 'event.user.input',
  version: 1,
  is: (event: { kind?: string } | undefined) => event?.kind === 'event.user.input',
}

type Conversation = {
  id: number
  parentConversationId?: number
  ownerTaskId?: number
  label?: string
  title?: string
  cwd: string
  inputAt?: number
  answerAt?: number
}
type Row = { id: number; handle?: string; title?: string; cwd: string; activeAt?: number }
type Host = {
  home: string
  userHome: string
  metadata: unknown
  conversations(): Conversation[]
  harness(): any
  doc(kind: string): any
  emit(tx: unknown, event: unknown, data: unknown): Promise<void> | void
  onOpen(callback: (opened?: Opened) => Promise<void>): void
  onRelease?(callback: () => Promise<void>): void
  onClose?(callback: () => Promise<void>): void
}
type Opened = { defer(cleanup: () => Promise<void>): void }
let current: ReturnType<typeof start> | null = null
const traceTarget = process.env.KEYSCRIBE_ULTIMATE_TRACE || null
let traced = 0
const traceFields = [
  'op', 'session', 'on', 'draft', 'newConversation', 'pageConversation',
  'prompts', 'turn', 'reason', 'request', 'id', 'sent', 'withDraft', 'state', 'protocolVersion',
  'page', 'seq', 'focused', 'conversation', 'parent',
] as const

export function summarizeTraceRecord(record: Record<string, unknown>, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const out: Record<string, unknown> = { ...extra }
  for (const key of traceFields) if (record[key] !== undefined) out[key] = record[key]
  if (typeof record.problem === 'string' && record.problem.length > 0) out.hasProblem = true
  return out
}

export function summarizeBridgeBody(path: string, body: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>
    return summarizeTraceRecord(parsed, { path })
  } catch {
    return { path }
  }
}

export function watchFolder(folder: string, changed: () => void, broken: () => void): (() => void) | null {
  try {
    const watcher = watch(folder, { persistent: false }, () => changed())
    watcher.on('error', () => {
      watcher.close()
      broken()
    })
    return () => watcher.close()
  } catch {
    return null
  }
}

function trace(dir: string, entry: Record<string, unknown>) {
  if (!traceTarget || traced >= traceLimit) return
  traced += 1
  try { appendFileSync(traceTarget, JSON.stringify({ at: Date.now(), dir, ...entry }) + '\n') } catch {}
}

function post(socketPath: string, path: string, body: string, token: string): Exchange {
  if (traceTarget) trace('ext->hub', summarizeBridgeBody(path, body))
  let cancel = () => {}
  const response = new Promise<Response>((resolve, reject) => {
    const req = request(
      {
        socketPath,
        path,
        method: 'POST',
        headers: {
          authorization: 'Bearer ' + token,
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(body),
          connection: 'close',
        },
      },
      (res) => {
        const chunks: Buffer[] = []
        let size = 0
        res.on('data', (chunk: Buffer) => {
          size += chunk.length
          if (size > responseLimit) return req.destroy(new Error('too large'))
          chunks.push(chunk)
        })
        res.on('end', () => {
          const status = res.statusCode || 0
          if (traceTarget) trace('hub->ext', { path, status })
          resolve({ status, ok: status >= 200 && status < 300, text: Buffer.concat(chunks).toString('utf8') })
        })
        res.on('error', reject)
      },
    )
    req.on('error', reject)
    cancel = () => req.destroy(new Error('cancelled'))
    req.end(body)
  })
  return { response, cancel: () => cancel() }
}

function settings(): Config | null {
  try {
    return JSON.parse(readFileSync(join(here, 'keyscribe.json'), 'utf8')) as Config
  } catch {
    return null
  }
}

function textOf(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .filter((part) => part && part.type === 'text' && typeof part.text === 'string')
    .map((part) => part.text as string)
    .join('\n')
}

export function served(host: Pick<Host, 'home'>, config: Pick<Config, 'setup'> | null): boolean {
  if (!config?.setup) return false
  try {
    const projects = realpathSync(join(config.setup, 'projects')) + '/'
    return realpathSync(host.home).startsWith(projects)
  } catch {
    return false
  }
}

export function unlistedReason(c: Pick<Conversation, 'id' | 'label'>): string | undefined {
  if (c.id === root) return 'Ultimate shows its root context, which has no writable composer.'
  if (c.label === 'lander') return 'Ultimate shows its lander, which has no writable composer.'
  return undefined
}

function row(c: Conversation): Row {
  const handle = c.label === standing ? c.title : c.label && !roles.has(c.label) ? c.label : undefined
  const active = Math.max(c.inputAt ?? -1, c.answerAt ?? -1)
  return { id: c.id, ...(handle ? { handle } : {}), ...(c.title ? { title: c.title } : {}), cwd: c.cwd,
    ...(active >= 0 ? { activeAt: Math.floor(active / 1000) } : {}) }
}

export function listing(host: Pick<Host, 'conversations'>, fresh: Conversation[] = []): Row[] {
  const listed = host.conversations().filter(c => unlistedReason(c) === undefined)
  const known = new Set(listed.map(c => c.id))
  return [...listed, ...fresh.filter(c => !known.has(c.id) && unlistedReason(c) === undefined)].map(row)
}

export function verifiesShown(host: Pick<Host, 'conversations'>, report: PageReport, fresh: Conversation[]): boolean {
  const shown = report.conversation
  return report.focused && !report.problem && shown !== null
    && !host.conversations().some(c => c.id === shown) && !fresh.some(c => c.id === shown)
}

export function busyChanged(busy: Set<number>, tasks: Record<string, { conversationId: number; background?: boolean }>): boolean {
  const now = new Set(Object.values(tasks ?? {}).filter((task) => !task.background).map((task) => task.conversationId))
  if (now.size === busy.size && [...now].every((id) => busy.has(id))) return false
  busy.clear()
  for (const id of now) busy.add(id)
  return true
}

export async function pageConversation(host: Pick<Host, 'harness' | 'metadata'>, id: number): Promise<Conversation | undefined> {
  if (!Number.isSafeInteger(id) || id <= root) return undefined
  const harness = host.harness()
  const conversation = await harness.conversation(id, context)
  if (!conversation) return undefined
  const metadata = await harness.snapshot(host.metadata, id, context)
  const value = { id, label: metadata?.label, title: metadata?.title, cwd: '' }
  if (unlistedReason(value) !== undefined) return undefined
  value.cwd = (await conversation.agent(context)).cwd
  return value
}

function start(host: Host, config: Config) {
  const harness = host.harness()
  const busy = new Set<number>()
  const generated = new Map<number, string | undefined>()
  const titled = new Map<number, string | undefined>()
  const summaries = host.doc('ultimate.conversation-summaries')
  const board = host.doc('board')
  const now = () => Date.now()
  const fresh = new Map<number, { conversation: Conversation; expires: number }>()
  const stillFresh = () => [...fresh.values()].filter(value => value.expires > now()).map(value => value.conversation)
  const rows = () => listing(host, stillFresh())

  const list = (): Summary[] => {
    const labels = new Map(host.conversations().map(c => [c.id, c.label]))
    for (const c of stillFresh()) labels.set(c.id, c.label)
    return rows().map((c) => ({
      id: c.id,
      title: c.title,
      named: labels.get(c.id) === standing ? c.title !== undefined : namedByUser(titled.get(c.id), generated.get(c.id)),
      cwd: c.cwd,
      busy: busy.has(c.id),
    }))
  }

  async function submit(id: number, text: string, images: Image[], requestId: string): Promise<number> {
    const conversation = await harness.conversation(id as ConversationId, context)
    if (!conversation) throw new Error('Ultimate no longer has this conversation.')
    const content = images.length
      ? [...(text.trim() ? [{ type: 'text', text }] : []), ...images.map((image) => ({ type: 'image', ...image }))]
      : text
    const submission = await conversation.submit({ type: 'input', content, whenBusy: 'steer', requestId }, context)
    const status = await submission.status(context)
    await harness.commit(
      (tx: unknown) =>
        host.emit(tx, userInputEvent, {
          conversation: id,
          kind: status.status !== 'queued' ? 'prompt' : 'steer',
          ...(status.entry === undefined ? { submission: submission.id } : { entry: status.entry }),
          length: text.length,
        }),
      context,
    )
    return submission.id as number
  }

  const connector = keyscribe(
    { version: '', home: realpathSync(host.home), list, submit,
      unavailable: id => unlistedReason(host.conversations().find(c => c.id === id) ?? { id }) ?? `Ultimate shows conversation ${id}, but it is not listed.` },
    {
      pid: process.pid,
      now,
      read: (path) => readFile(path, 'utf8'),
      readBase64: async (path) => (await readFile(path)).toString('base64'),
      after: (ms, fn) => {
        const timer = setTimeout(fn, ms)
        timer.unref?.()
        return () => clearTimeout(timer)
      },
      post,
      random: () => randomBytes(6).toString('hex'),
      log: (message) => console.log(`${name}: ${message}`),
      watch: watchFolder,
    },
    async () => config,
  )

  let pending = false
  let again: ReturnType<typeof setTimeout> | null = null
  const refresh = () => {
    if (!pending) {
      pending = true
      queueMicrotask(() => {
        pending = false
        connector.changed()
      })
    }
    if (again) clearTimeout(again)
    again = setTimeout(() => {
      again = null
      connector.changed()
    }, listSettles)
    again.unref?.()
  }

  function questions(value: { messages?: unknown }) {
    const open = new Map<number, Waiting>()
    const messages = Array.isArray(value?.messages) ? value.messages : []
    for (const message of messages) {
      if (!message || message.to !== 'user' || message.reply !== true || message.state !== 'delivered') continue
      if (typeof message.from !== 'number' || open.has(message.from)) continue
      open.set(message.from, waitingFor(typeof message.text === 'string' ? message.text : '', message.questions))
    }
    connector.waiting(open)
  }

  function entry(record: EntryRecord) {
    const message: any = Array.isArray(record.model) ? record.model[0] : undefined
    if (record.input && message?.role === 'user')
      connector.input(record.conversationId as number, record.id as number, record.kind, textOf(message.content))
    else if (record.kind === 'pi.assistant' && message?.role === 'assistant')
      connector.replied(record.conversationId as number, textOf(message.content), message.stopReason)
  }

  const watchingCommitsForEntriesSubmissionsAndQuestionsWhichPiRecordsWithoutDomainEvents = harness.observeCommits({
    advance: (publication: CommitPublication) => {
      const changes = publication.changes as any[]
      for (const change of changes)
        if (change.type === 'submission' && change.value.status === 'placed')
          connector.placed(change.value.id, change.value.entry, change.value.requestId)
      for (const change of changes) {
        if (change.type === 'entry') entry(change.value)
        else if (change.type === 'conversation') refresh()
        else if (change.type === 'document' && change.kind === 'change') {
          if (change.record.kind === 'board') questions(change.value)
          else if (change.record.kind === 'ultimate.conversation-summaries' && change.conversationId !== undefined) {
            generated.set(change.conversationId, change.value?.generatedTitle)
            refresh()
          } else if (change.record.kind === 'ultimate.metadata') {
            if (change.conversationId !== undefined) titled.set(change.conversationId, change.value?.title)
            refresh()
          }
        }
      }
    },
    end: () => {},
  })

  let graph: { detach(): void } | null = null
  void harness
    .observeTaskGraph(
      {
        advance: (call: any) => {
          if (call.kind === 'value' && busyChanged(busy, call.value.tasks)) refresh()
        },
        end: () => {},
      },
      context,
    )
    .then((observation: any) => {
      graph = observation
      busyChanged(busy, observation.value.tasks)
      refresh()
    })

  void (async () => {
    for (const c of host.conversations()) {
      if (c.label === standing || unlistedReason(c) !== undefined) continue
      const metadata = await harness.snapshot(host.metadata, c.id, context).catch(() => undefined)
      titled.set(c.id, metadata?.title)
      if (!summaries) continue
      const value = await harness.snapshot(summaries, c.id, context).catch(() => undefined)
      generated.set(c.id, value?.generatedTitle)
    }
    if (board) questions((await harness.snapshot(board, root, context).catch(() => undefined)) ?? {})
    refresh()
  })()

  const rememberFresh = async (id: number) => {
    const conversation = await pageConversation(host, id).catch(() => undefined)
    if (!conversation) return
    for (const [key, value] of fresh) if (value.expires <= now()) fresh.delete(key)
    if (fresh.size >= freshLimit) fresh.delete(fresh.keys().next().value!)
    fresh.set(conversation.id, { conversation, expires: now() + freshFor })
    connector.changed()
  }

  return {
    connector,
    list: rows,
    page: async (report: PageReport) => {
      if (verifiesShown(host, report, stillFresh()) && report.conversation !== null) await rememberFresh(report.conversation)
      connector.page(report)
    },
    started: async (id: string, page: string, result: { sent: boolean; withDraft?: boolean; reason?: string; detail?: string; conversation?: number }) => {
      if (result.sent && typeof result.conversation === 'number') await rememberFresh(result.conversation)
      return connector.started(id, page, result)
    },
    close: () => {
      if (again) clearTimeout(again)
      watchingCommitsForEntriesSubmissionsAndQuestionsWhichPiRecordsWithoutDomainEvents.detach()
      graph?.detach()
      connector.stop()
    },
  }
}

export function opener<T extends { close(): void }>(
  serves: () => boolean, begin: () => T, publish: { started(value: T): void; ended(value: T): void },
) {
  let running: T | null = null
  const end = (started: T) => async () => {
    if (running !== started) return
    running = null
    publish.ended(started)
    started.close()
  }
  return {
    open: async (opened?: Opened) => {
      if (running || !serves()) return
      const started = begin()
      running = started
      publish.started(started)
      if (typeof opened?.defer === 'function') opened.defer(end(started))
    },
    close: async () => {
      if (running) await end(running)()
    },
  }
}

export const userActions = ['list', 'page', 'next', 'composed', 'started', 'readAloud', 'label']

function args(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

export const actions = {
  async list() {
    if (!current) throw new Error('The Ultimate connector is not ready.')
    return current.list()
  },
  async page(value: unknown) {
    const { page, seq, focused, conversation, draft, newConversation, parent, pageConversation, problem } = args(value)
    if (typeof page !== 'string') throw new Error('Expected a page')
    const report: PageReport = {
      page, focused: focused === true, conversation: typeof conversation === 'number' ? conversation : null, draft: draft === true,
      ...(typeof seq === 'number' && Number.isFinite(seq) ? { seq } : {}),
      ...(newConversation === true ? { newConversation: true } : {}),
      ...(typeof parent === 'number' ? { parent } : {}),
      ...(typeof pageConversation === 'number' ? { pageConversation } : {}),
      ...(typeof problem === 'string' ? { problem: problem.slice(0, 300) } : {}),
    }
    if (traceTarget) trace('page->ext', summarizeTraceRecord(report as unknown as Record<string, unknown>))
    await current?.page(report)
    return {}
  },
  async next(value: unknown) {
    const { page } = args(value)
    if (typeof page !== 'string') throw new Error('Expected a page')
    return { ask: (await current?.connector.nextCompose(page)) ?? null }
  },
  async composed(value: unknown) {
    const { id, page, draft } = args(value)
    if (typeof id !== 'string' || typeof page !== 'string' || typeof draft !== 'string') throw new Error('Expected a request, page and draft')
    return { sent: (await current?.connector.composed(id, page, draft)) ?? false }
  },
  async started(value: unknown) {
    const { id, page, sent, withDraft, reason, detail, conversation } = args(value)
    if (typeof id !== 'string' || typeof page !== 'string') throw new Error('Expected a request and page')
    const ok = await current?.started(id, page, {
      sent: sent === true,
      ...(withDraft === true ? { withDraft: true } : {}),
      ...(typeof reason === 'string' ? { reason } : {}),
      ...(typeof detail === 'string' ? { detail: detail.slice(0, 200) } : {}),
      ...(typeof conversation === 'number' ? { conversation } : {}),
    })
    return { ok: ok ?? false }
  },
  async label(value: unknown) {
    const { conversation } = args(value)
    if (typeof conversation !== 'number') throw new Error('Expected a conversation')
    return { label: current?.connector.label(conversation) ?? null }
  },
  async readAloud(value: unknown) {
    const { conversation, on } = args(value)
    if (typeof conversation !== 'number') throw new Error('Expected a conversation')
    if (!current) return { message: `${appNameOf(null)} isn’t connected to this project.` }
    return { message: await current.connector.command(conversation, on !== false) }
  },
}

export default (host: Host) => {
  const config = settings()
  const app = appNameOf(config)
  const tool = readAloudToolName(config?.plugin ?? name)
  const lifecycle = opener(
    () => config !== null && served(host, config),
    () => start(host, config!),
    { started: (value) => { current = value }, ended: (value) => { if (current === value) current = null } },
  )
  host.onOpen(lifecycle.open)
  host.onRelease?.(lifecycle.close)
  host.onClose?.(lifecycle.close)
  return defineExtension({
    name,
    tools: [
      defineTool({
        name: tool,
        description:
          `The user has ${app}, a voice app on this Mac. Call this only when the user explicitly asks ${app}, or asks to hear it out loud, ` +
          `to report when the current work is done. Call it once, then keep working. When this turn ends, ${app} reports your final reply. ` +
          `If the work is already finished, answer instead of calling it. Not for a plain "let me know".`,
        parameters: obj({}),
        replay: 'safe',
        async execute(_args: unknown, api: { conversationId: ConversationId }) {
          const answer = current ? await current.connector.readAloud(api.conversationId as number) : null
          return { output: [{ type: 'text', text: readAloudReply(app, answer) }] }
        },
      } as any),
    ],
  })
}
