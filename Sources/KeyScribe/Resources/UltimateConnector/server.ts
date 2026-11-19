import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context'
import { defineExtension, defineTool } from '@earendil-works/pi-durable'
import type { CommitPublication, ConversationId, EntryRecord } from '@earendil-works/pi-durable'
import { obj } from '@earendil-works/pi-schema'
import { randomBytes } from 'node:crypto'
import { readFileSync, realpathSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { request } from 'node:http'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appNameOf, keyscribe, readAloudReply, readAloudToolName, waitingFor } from './keyscribe.ts'
import type { Config, Exchange, Image, PageReport, Response, Summary, Waiting } from './keyscribe.ts'

const here = dirname(fileURLToPath(import.meta.url))
const name = basename(here)
const responseLimit = 512 * 1024
const listSettles = 1000
const root = 1
const standing = 'agent'
const unaddressed = new Set(['lander', 'side-chat'])
const userInputEvent = {
  name: 'user.input',
  kind: 'event.user.input',
  version: 1,
  is: (event: { kind?: string } | undefined) => event?.kind === 'event.user.input',
}

type Host = {
  home: string
  userHome: string
  conversations(): Array<{
    id: number
    parentConversationId?: number
    ownerTaskId?: number
    label?: string
    title?: string
    cwd: string
  }>
  harness(): any
  doc(kind: string): any
  emit(tx: unknown, event: unknown, data: unknown): Promise<void> | void
  onOpen(callback: () => Promise<void>): void
  onRelease(callback: () => Promise<void>): void
  onClose(callback: () => Promise<void>): void
}
type Connector = ReturnType<typeof keyscribe>

let current: Connector | null = null

function post(socketPath: string, path: string, body: string, token: string): Exchange {
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

function served(host: Host, config: Config | null): boolean {
  if (!config?.setup) return false
  const projects = join(config.setup, 'projects') + '/'
  try {
    return realpathSync(host.home).startsWith(projects)
  } catch {
    return false
  }
}

function start(host: Host, config: Config) {
  const harness = host.harness()
  const busy = new Set<number>()
  const generated = new Map<number, string | undefined>()
  const summaries = host.doc('ultimate.conversation-summaries')
  const board = host.doc('board')

  const addressable = () =>
    host
      .conversations()
      .filter(
        (c) =>
          c.parentConversationId === undefined &&
          c.ownerTaskId === undefined &&
          c.id !== root &&
          !unaddressed.has(c.label ?? '') &&
          (c.label === undefined || c.label === standing),
      )

  const list = (): Summary[] =>
    addressable().map((c) => ({
      id: c.id,
      title: c.title,
      named: c.label === standing ? c.title !== undefined : c.title !== undefined && generated.has(c.id) && generated.get(c.id) !== c.title,
      cwd: c.cwd,
      busy: busy.has(c.id),
    }))

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
    { version: '', home: realpathSync(host.home), list, submit },
    {
      pid: process.pid,
      now: () => Date.now(),
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
          } else if (change.record.kind === 'ultimate.metadata') refresh()
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
          if (call.kind !== 'value') return
          busy.clear()
          for (const task of Object.values(call.value.tasks) as any[]) if (!task.background) busy.add(task.conversationId)
          refresh()
        },
        end: () => {},
      },
      context,
    )
    .then((observation: any) => {
      graph = observation
      busy.clear()
      for (const task of Object.values(observation.value.tasks) as any[]) if (!task.background) busy.add(task.conversationId)
      refresh()
    })

  void (async () => {
    for (const c of addressable()) {
      if (c.label === standing || !summaries) continue
      const value = await harness.snapshot(summaries, c.id, context).catch(() => undefined)
      generated.set(c.id, value?.generatedTitle)
    }
    if (board) questions((await harness.snapshot(board, root, context).catch(() => undefined)) ?? {})
    refresh()
  })()

  return {
    connector,
    close: () => {
      if (again) clearTimeout(again)
      watchingCommitsForEntriesSubmissionsAndQuestionsWhichPiRecordsWithoutDomainEvents.detach()
      graph?.detach()
      connector.stop()
    },
  }
}

export const userActions = ['page', 'next', 'composed', 'readAloud', 'label']

function args(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

export const actions = {
  async page(value: unknown) {
    const { page, focused, conversation, draft } = args(value)
    if (typeof page !== 'string') throw new Error('Expected a page')
    current?.page({ page, focused: focused === true, conversation: typeof conversation === 'number' ? conversation : null, draft: draft === true } satisfies PageReport)
    return {}
  },
  async next(value: unknown) {
    const { page } = args(value)
    if (typeof page !== 'string') throw new Error('Expected a page')
    return { ask: (await current?.nextCompose(page)) ?? null }
  },
  async composed(value: unknown) {
    const { id, page, draft } = args(value)
    if (typeof id !== 'string' || typeof page !== 'string' || typeof draft !== 'string') throw new Error('Expected a request, page and draft')
    return { sent: (await current?.composed(id, page, draft)) ?? false }
  },
  async label(value: unknown) {
    const { conversation } = args(value)
    if (typeof conversation !== 'number') throw new Error('Expected a conversation')
    return { label: current?.label(conversation) ?? null }
  },
  async readAloud(value: unknown) {
    const { conversation, on } = args(value)
    if (typeof conversation !== 'number') throw new Error('Expected a conversation')
    if (!current) return { message: `${appNameOf(null)} isn’t connected to this project.` }
    return { message: await current.command(conversation, on !== false) }
  },
}

export default (host: Host) => {
  const config = settings()
  const app = appNameOf(config)
  const tool = readAloudToolName(config?.plugin ?? name)
  let running: ReturnType<typeof start> | null = null
  host.onOpen(async () => {
    if (running || !served(host, config) || !config) return
    running = start(host, config)
    current = running.connector
  })
  const close = async () => {
    if (running && current === running.connector) current = null
    running?.close()
    running = null
  }
  host.onRelease(close)
  host.onClose(close)
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
          const answer = current ? await current.readAloud(api.conversationId as number) : null
          return { output: [{ type: 'text', text: readAloudReply(app, answer) }] }
        },
      } as any),
    ],
  })
}
