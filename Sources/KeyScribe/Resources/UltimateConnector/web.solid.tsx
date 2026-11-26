import { createEffect, createMemo, createSignal, onSettled, Show } from 'solid-js'
import { joined, runsAsCommand } from './keyscribe.ts'
import {
  draftOf, editorOf, keepReporting, labelOf, pageNow, reportOf, subscribe, subscribeLabels, type PageNow, type Shown,
} from './page.ts'
import { actionRef, api, defineWebExtension, fillComposer, setUiState, useConversationId, useSurface } from '@/sdk/solid'

const extension = 'keyscribe'
type Ask = { id: string; kind?: 'start'; conversation: number; text: string }
const PageAction = actionRef<{
  page: string; seq?: number; focused: boolean; conversation: number | null; draft: boolean
  newConversation?: boolean; parent?: number; pageConversation?: number | null; problem?: string
  labelsOf?: number[]
}, { labels?: Record<string, string> }>(extension, 'page')
const NextAction = actionRef<
  Shown & { page: string; seq: number; asking: boolean; labelsOf: number[]; labels: Record<string, string> },
  { ask: Ask | null; labels?: Record<string, string> }
>(extension, 'next')
const ComposedAction = actionRef<{ id: string; page: string; draft: string }, { sent: boolean }>(extension, 'composed')
const StartedAction = actionRef<{
  id: string; page: string; sent: boolean; withDraft?: boolean; reason?: string; detail?: string; conversation?: number
}, { ok: boolean }>(extension, 'started')
const SideChatOpenAction = actionRef<{ text: string }, { id: number }>('side-chat', 'open')
const ReadAloudAction = actionRef<{ conversation: number; on: boolean }, { message: string }>(extension, 'readAloud')

const page = Math.random().toString(36).slice(2, 12)
let reportSeq = 0
const answerShown = 6000

function shownConversation(): () => number | null {
  const conversationId = useConversationId()
  return () => {
    const id = conversationId()
    return typeof id === 'number' ? id : null
  }
}

function Reporter() {
  const conversationShown = shownConversation()
  const surface = useSurface()
  const [changed, setChanged] = createSignal(0)
  onSettled(() => {
    const bump = () => setChanged(count => count + 1)
    const unsubscribe = subscribe(bump)
    bump()
    return unsubscribe
  })
  const snapshot = createMemo(() => {
    changed()
    return JSON.stringify(pageNow(conversationShown(), surface() === 'agent'))
  })
  const now = createMemo(() => JSON.parse(snapshot()) as PageNow)
  const watched = createMemo(() => JSON.stringify({ report: reportOf(now()), labelsOf: now().labelsOf }))

  onSettled(() => {
    const leave = () => {
      void api.action(
        PageAction,
        { page, seq: ++reportSeq, focused: false, conversation: null, draft: false, pageConversation: null },
        { keepalive: true },
      ).catch(() => undefined)
    }
    window.addEventListener('pagehide', leave)
    return () => window.removeEventListener('pagehide', leave)
  })

  createEffect(watched, (watch) => {
    const { report, labelsOf } = JSON.parse(watch) as { report: Shown; labelsOf: number[] }
    const controller = new AbortController()
    const { signal } = controller
    void keepReporting<Ask>({
      report,
      labelsOf,
      signal,
      tell: (labelsOf) => api.action(PageAction, { page, seq: ++reportSeq, ...report, labelsOf }, { signal }),
      ask: (asking, labelsOf, labels) =>
        api.action(NextAction, { page, seq: ++reportSeq, ...report, asking, labelsOf, labels }, { signal }),
      handle: async (ask) => {
        if (ask.kind === 'start') {
          const editor = editorOf(ask.conversation)
          if (!editor || !editor.closest('[data-side-mode="side"]')) {
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'gone' }).catch(() => undefined)
            return
          }
          const before = editor.value
          const hasDraft = before.trim() !== ''
          if (hasDraft && (runsAsCommand(before) || runsAsCommand(ask.text))) {
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'draft' }).catch(() => undefined)
            return
          }
          const text = hasDraft ? joined(before, ask.text) : ask.text
          let opened: { id: number }
          try {
            opened = await api.action(SideChatOpenAction, { text }, { conversationId: ask.conversation as any })
          } catch (error) {
            const detail = error instanceof Error ? error.message : String(error)
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'failed', detail: detail.slice(0, 200) }).catch(() => undefined)
            return
          }
          try {
            if (hasDraft && editorOf(ask.conversation)?.value === before) fillComposer(ask.conversation, '')
            document.querySelector<HTMLButtonElement>('[data-ui="side-chat-switch"][aria-pressed="true"]')?.click()
            setUiState('ext.side-chat.front', opened.id)
          } catch {}
          await api.action(StartedAction, { id: ask.id, page, sent: true, withDraft: hasDraft, conversation: opened.id }).catch(() => undefined)
          return
        }
        const before = draftOf(ask.conversation)
        const { sent } = await api
          .action(ComposedAction, { id: ask.id, page, draft: before })
          .catch(() => ({ sent: false }))
        if (sent && editorOf(ask.conversation) && draftOf(ask.conversation) === before) fillComposer(ask.conversation, '')
      },
    })
    return () => controller.abort()
  })

  return null
}

function Name() {
  const conversation = shownConversation()
  const [labelsChanged, setLabelsChanged] = createSignal(0)
  onSettled(() => {
    const bump = () => setLabelsChanged(count => count + 1)
    const unsubscribe = subscribeLabels(bump)
    bump()
    return unsubscribe
  })
  const label = createMemo(() => {
    labelsChanged()
    return labelOf(conversation())
  })
  return <Show when={label()}>{(text) => <span class="truncate text-muted-foreground">{text()}</span>}</Show>
}

const [answer, setAnswer] = createSignal<string | null>(null)
let answerTimer: number | undefined

function say(message: string) {
  setAnswer(message)
  window.clearTimeout(answerTimer)
  answerTimer = window.setTimeout(() => setAnswer(null), answerShown)
}

function Answer() {
  return (
    <Show when={answer()}>
      {(text) => (
        <div
          role="status"
          class="pointer-events-none fixed bottom-20 left-1/2 z-50 max-w-md -translate-x-1/2 rounded-md border border-border bg-popover px-3 py-2 text-sm text-popover-foreground shadow-md"
        >
          {text()}
        </div>
      )}
    </Show>
  )
}

async function readAloud(conversation: number | undefined, on: boolean) {
  if (typeof conversation !== 'number') return
  const { message } = await api.action(ReadAloudAction, { conversation, on })
  say(message)
}

export default defineWebExtension({
  slots: { overlay: [Reporter, Answer], 'composer.status': [Name] },
  commands: [
    {
      id: `${extension}.readAloud`,
      title: 'Read this reply aloud when done',
      run: (context) => readAloud(context.conversationId, true),
    },
    {
      id: `${extension}.readAloud.cancel`,
      title: 'Don’t read this reply aloud',
      run: (context) => readAloud(context.conversationId, false),
    },
  ],
})
