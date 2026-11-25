import { createEffect, createMemo, createSignal, onSettled, Show } from 'solid-js'
import { joined, runsAsCommand } from './keyscribe.ts'
import { composerNow, draftOf, editorOf, focusedNow, heartbeat, subscribe, type Shown } from './page.ts'
import { actionRef, api, defineWebExtension, fillComposer, setUiState, useConversationId, useSurface } from '@/sdk/solid'

const extension = 'keyscribe'
type Ask = { id: string; kind?: 'start'; conversation: number; text: string }
const PageAction = actionRef<{
  page: string; seq?: number; focused: boolean; conversation: number | null; draft: boolean
  newConversation?: boolean; parent?: number; pageConversation?: number | null; problem?: string
}, object>(extension, 'page')
const NextAction = actionRef<{ page: string }, { ask: Ask | null }>(extension, 'next')
const ComposedAction = actionRef<{ id: string; page: string; draft: string }, { sent: boolean }>(extension, 'composed')
const StartedAction = actionRef<{
  id: string; page: string; sent: boolean; withDraft?: boolean; reason?: string; detail?: string; conversation?: number
}, { ok: boolean }>(extension, 'started')
const SideChatOpenAction = actionRef<{ text: string }, { id: number }>('side-chat', 'open')
const ReadAloudAction = actionRef<{ conversation: number; on: boolean }, { message: string }>(extension, 'readAloud')
const LabelAction = actionRef<{ conversation: number }, { label: string | null }>(extension, 'label')

const page = Math.random().toString(36).slice(2, 12)
let reportSeq = 0
const answerShown = 6000
const retryPause = 2000


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
    return JSON.stringify({ ...composerNow(conversationShown(), surface() === 'agent'), focused: focusedNow() })
  })
  const shown = createMemo(() => JSON.parse(snapshot()) as Shown)
  const asking = createMemo(() => {
    const { focused, draft, newConversation } = shown()
    return focused && (draft || newConversation === true)
  })

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

  createEffect(shown, (now) => {
    const controller = new AbortController()
    const report = () => api.action(PageAction, { page, seq: ++reportSeq, ...now }, { signal: controller.signal }).catch(() => undefined)
    void report()
    const timer = now.focused ? window.setInterval(report, heartbeat) : undefined
    return () => {
      controller.abort()
      window.clearInterval(timer)
    }
  })

  createEffect(asking, (active) => {
    if (!active) return undefined
    const controller = new AbortController()
    void (async () => {
      while (!controller.signal.aborted) {
        let ask: Ask | null = null
        try {
          ask = (await api.action(NextAction, { page }, { signal: controller.signal })).ask
        } catch {
          if (controller.signal.aborted) return
          await new Promise((resolve) => window.setTimeout(resolve, retryPause))
          continue
        }
        if (!ask || controller.signal.aborted) continue
        if (ask.kind === 'start') {
          const editor = editorOf(ask.conversation)
          if (!editor || !editor.closest('[data-side-mode="side"]')) {
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'gone' }).catch(() => undefined)
            continue
          }
          const before = editor.value
          const hasDraft = before.trim() !== ''
          if (hasDraft && (runsAsCommand(before) || runsAsCommand(ask.text))) {
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'draft' }).catch(() => undefined)
            continue
          }
          const text = hasDraft ? joined(before, ask.text) : ask.text
          let opened: { id: number }
          try {
            opened = await api.action(SideChatOpenAction, { text }, { conversationId: ask.conversation as any })
          } catch (error) {
            const detail = error instanceof Error ? error.message : String(error)
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'failed', detail: detail.slice(0, 200) }).catch(() => undefined)
            continue
          }
          try {
            if (hasDraft && editorOf(ask.conversation)?.value === before) fillComposer(ask.conversation, '')
            document.querySelector<HTMLButtonElement>('[data-ui="side-chat-switch"][aria-pressed="true"]')?.click()
            setUiState('ext.side-chat.front', opened.id)
          } catch {}
          await api.action(StartedAction, { id: ask.id, page, sent: true, withDraft: hasDraft, conversation: opened.id }).catch(() => undefined)
          continue
        }
        const before = draftOf(ask.conversation)
        const { sent } = await api
          .action(ComposedAction, { id: ask.id, page, draft: before })
          .catch(() => ({ sent: false }))
        if (sent && editorOf(ask.conversation) && draftOf(ask.conversation) === before) fillComposer(ask.conversation, '')
      }
    })()
    return () => controller.abort()
  })

  return null
}

function Name() {
  const conversation = shownConversation()
  const [label, setLabel] = createSignal<string | null>(null)
  createEffect(conversation, (id) => {
    setLabel(null)
    if (id === null) return undefined
    let live = true
    const read = () => {
      if (document.visibilityState !== 'visible') return
      api.action(LabelAction, { conversation: id }).then((answer) => live && setLabel(answer.label), () => undefined)
    }
    read()
    const timer = window.setInterval(read, heartbeat)
    return () => {
      live = false
      window.clearInterval(timer)
    }
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
