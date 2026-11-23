import { useEffect, useState, useSyncExternalStore } from 'react'
import { automatedBrowser, joined, runsAsCommand, typingTarget } from './keyscribe.ts'
import { actionRef, api, defineWebExtension, fillComposer, useUltimate } from '@/sdk'

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
const heartbeat = 5000
const answerShown = 6000
const retryPause = 2000

function visible(editor: HTMLElement): boolean {
  return editor.getClientRects().length > 0 && !editor.closest('[inert], [aria-hidden="true"]')
}

function editorOf(conversation: number): HTMLTextAreaElement | undefined {
  return [...document.querySelectorAll<HTMLTextAreaElement>(`textarea[data-conversation="${conversation}"]`)]
    .find(editor => visible(editor) && !editor.disabled && !editor.readOnly)
}

function urlConversation(): number | null {
  try {
    const value = new URL(window.location.href).searchParams.get('conversation')
    if (!value || !/^\d+$/.test(value)) return null
    const id = Number(value)
    return Number.isSafeInteger(id) && id > 0 ? id : null
  } catch {
    return null
  }
}

function composerNow(shown: number | null = null): {
  conversation: number | null; draft: boolean; newConversation?: boolean; parent?: number; pageConversation: number | null; problem?: string
} {
  const editors = [...document.querySelectorAll<HTMLTextAreaElement>('textarea[data-conversation]')]
    .filter(editor => visible(editor) && !editor.disabled && !editor.readOnly)
  const blocked = [...document.querySelectorAll<HTMLElement>('[role="dialog"], [role="alertdialog"], dialog[open]')].some(visible)
  const target = typingTarget(editors.map(editor => ({
    id: Number(editor.dataset.conversation),
    active: document.activeElement === editor,
    sideMode: editor.closest('[data-side-mode="side"]') !== null,
  })), blocked)
  const pageConversation = urlConversation()
  if (target.kind === 'newSideChat') {
    return {
      conversation: null,
      draft: (editorOf(target.parent)?.value.trim() ?? '') !== '',
      newConversation: true,
      parent: target.parent,
      pageConversation,
    }
  }
  if (target.kind === 'conversation') {
    return {
      conversation: target.id,
      draft: (editorOf(target.id)?.value.trim() ?? '') !== '',
      pageConversation,
    }
  }
  const conversation = !blocked && editors.length === 0 ? shown : null
  return {
    conversation,
    draft: false,
    pageConversation,
    problem: blocked ? 'A dialog covers Ultimate’s composer.'
      : editors.length > 1 ? 'Ultimate has several writable composers. Click in the one to use.' : 'Ultimate’s composer is not ready.',
  }
}

function draftOf(conversation: number): string {
  const editor = editorOf(conversation)
  if (editor) return editor.value
  try {
    return localStorage.getItem(`ultimate.draft.${conversation}`) ?? ''
  } catch {
    return ''
  }
}

const composerParts = 'textarea[data-conversation], [role="dialog"], [role="alertdialog"], dialog'
const focusEvents = ['focus', 'blur', 'focusin', 'focusout', 'visibilitychange', 'input']

function touchesComposer(records: MutationRecord[]): boolean {
  for (const record of records) {
    if (record.type === 'attributes') return true
    for (const nodes of [record.addedNodes, record.removedNodes])
      for (const node of nodes)
        if (node instanceof Element && (node.matches(composerParts) || node.querySelector(composerParts) !== null)) return true
  }
  return false
}

function subscribe(listener: () => void) {
  for (const name of focusEvents) window.addEventListener(name, listener, true)
  const observer = new MutationObserver((records) => {
    if (touchesComposer(records)) listener()
  })
  observer.observe(document.body, { childList: true, subtree: true, attributes: true,
    attributeFilter: ['inert', 'hidden', 'aria-hidden', 'disabled', 'readonly', 'open', 'data-conversation', 'data-side-mode'] })
  const reread = window.setInterval(() => {
    if (document.visibilityState === 'visible') listener()
  }, heartbeat)
  return () => {
    for (const name of focusEvents) window.removeEventListener(name, listener, true)
    observer.disconnect()
    window.clearInterval(reread)
  }
}
const automated = automatedBrowser(navigator)
const focusedNow = () => !automated && document.visibilityState === 'visible' && document.hasFocus()
type Shown = {
  conversation: number | null; draft: boolean; newConversation?: boolean; parent?: number; pageConversation: number | null; problem?: string; focused: boolean
}

function Reporter() {
  const { conversationId } = useUltimate()
  const conversationShown = typeof conversationId === 'number' ? conversationId : null
  const snapshot = useSyncExternalStore(subscribe, () => JSON.stringify({ ...composerNow(conversationShown), focused: focusedNow() }))
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
          try {
            const opened = await api.action(SideChatOpenAction, { text }, { conversationId: ask.conversation as any })
            if (hasDraft && editorOf(ask.conversation)?.value === before) fillComposer(ask.conversation, '')
            document.querySelector<HTMLButtonElement>('[data-ui="side-chat-switch"][aria-pressed="true"]')?.click()
            await api.updateUi({ set: { 'ext.side-chat.front': opened.id } }).catch(() => undefined)
            await api.action(StartedAction, { id: ask.id, page, sent: true, withDraft: hasDraft, conversation: opened.id }).catch(() => undefined)
          } catch (error) {
            const detail = error instanceof Error ? error.message : String(error)
            await api.action(StartedAction, { id: ask.id, page, sent: false, reason: 'failed', detail: detail.slice(0, 200) }).catch(() => undefined)
          }
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
