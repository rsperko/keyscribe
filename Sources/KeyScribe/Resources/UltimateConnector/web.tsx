import { useEffect, useState, useSyncExternalStore } from 'react'
import { joined, runsAsCommand } from './keyscribe.ts'
import { composerNow, draftOf, editorOf, focusedNow, heartbeat, subscribe, type Shown } from './page.ts'
import { actionRef, api, defineWebExtension, fillComposer, useUiState, useUltimate } from '@/sdk'

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


function Reporter() {
  const { conversationId, surface } = useUltimate()
  const conversationShown = typeof conversationId === 'number' ? conversationId : null
  const home = surface === 'agent'
  const [, setFront] = useUiState<number | null>('ext.side-chat.front', null)
  const snapshot = useSyncExternalStore(subscribe, () => JSON.stringify({ ...composerNow(conversationShown, home), focused: focusedNow() }))
  const shown = JSON.parse(snapshot) as Shown
  const { focused, draft, newConversation } = shown

  useEffect(() => {
    const leave = () => {
      void api.action(
        PageAction,
        { page, seq: ++reportSeq, focused: false, conversation: null, draft: false, pageConversation: null },
        { keepalive: true },
      ).catch(() => undefined)
    }
    window.addEventListener('pagehide', leave)
    return () => window.removeEventListener('pagehide', leave)
  }, [])

  useEffect(() => {
    const controller = new AbortController()
    const report = () => api.action(PageAction, { page, seq: ++reportSeq, ...shown }, { signal: controller.signal }).catch(() => undefined)
    void report()
    if (!focused) return () => controller.abort()
    const timer = window.setInterval(report, heartbeat)
    return () => {
      controller.abort()
      window.clearInterval(timer)
    }
  }, [snapshot])

  useEffect(() => {
    if (!focused || (!draft && !newConversation)) return
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
            setFront(opened.id)
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
  }, [focused, draft, newConversation])

  return null
}

function Name() {
  const { conversationId } = useUltimate()
  const conversation = typeof conversationId === 'number' ? conversationId : null
  const [label, setLabel] = useState<string | null>(null)
  useEffect(() => {
    setLabel(null)
    if (conversation === null) return
    let live = true
    const read = () => {
      if (document.visibilityState !== 'visible') return
      api.action(LabelAction, { conversation }).then((answer) => live && setLabel(answer.label), () => undefined)
    }
    read()
    const timer = window.setInterval(read, heartbeat)
    return () => {
      live = false
      window.clearInterval(timer)
    }
  }, [conversation])
  if (!label) return null
  return <span className="truncate text-muted-foreground">{label}</span>
}

let say: ((message: string) => void) | null = null

function Answer() {
  const [message, setMessage] = useState<string | null>(null)
  useEffect(() => {
    let clear: number | undefined
    say = (text) => {
      setMessage(text)
      window.clearTimeout(clear)
      clear = window.setTimeout(() => setMessage(null), answerShown)
    }
    return () => {
      say = null
      window.clearTimeout(clear)
    }
  }, [])
  if (!message) return null
  return (
    <div
      role="status"
      className="pointer-events-none fixed bottom-20 left-1/2 z-50 max-w-md -translate-x-1/2 rounded-md border border-border bg-popover px-3 py-2 text-sm text-popover-foreground shadow-md"
    >
      {message}
    </div>
  )
}

async function readAloud(conversation: number | undefined, on: boolean) {
  if (typeof conversation !== 'number') return
  const { message } = await api.action(ReadAloudAction, { conversation, on })
  say?.(message)
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
