import { useEffect, useState, useSyncExternalStore } from 'react'
import { actionRef, api, defineWebExtension, fillComposer, useUltimate } from '@/sdk'

const extension = 'keyscribe'
type Ask = { id: string; conversation: number; text: string }
const PageAction = actionRef<{ page: string; focused: boolean; conversation: number | null; draft: boolean }, object>(extension, 'page')
const NextAction = actionRef<{ page: string }, { ask: Ask | null }>(extension, 'next')
const ComposedAction = actionRef<{ id: string; page: string; draft: string }, { sent: boolean }>(extension, 'composed')
const ReadAloudAction = actionRef<{ conversation: number; on: boolean }, { message: string }>(extension, 'readAloud')
const LabelAction = actionRef<{ conversation: number }, { label: string | null }>(extension, 'label')

const page = Math.random().toString(36).slice(2, 12)
const heartbeat = 5000
const answerShown = 6000
const retryPause = 2000

function draftOf(conversation: number): string {
  const editor = document.querySelector<HTMLTextAreaElement>(`textarea[data-conversation="${conversation}"]`)
  if (editor) return editor.value
  try {
    return localStorage.getItem(`ultimate.draft.${conversation}`) ?? ''
  } catch {
    return ''
  }
}

const focusEvents = ['focus', 'blur', 'visibilitychange', 'input', 'keyup']
function subscribe(listener: () => void) {
  for (const name of focusEvents) window.addEventListener(name, listener, true)
  document.addEventListener('visibilitychange', listener)
  return () => {
    for (const name of focusEvents) window.removeEventListener(name, listener, true)
    document.removeEventListener('visibilitychange', listener)
  }
}
const focusedNow = () => document.visibilityState === 'visible' && document.hasFocus()

function Reporter() {
  const { conversationId } = useUltimate()
  const conversation = typeof conversationId === 'number' ? conversationId : null
  const focused = useSyncExternalStore(subscribe, focusedNow)
  const [draft, setDraft] = useState(false)

  useEffect(() => {
    if (conversation === null) return setDraft(false)
    const read = () => setDraft(draftOf(conversation).trim() !== '')
    read()
    return subscribe(read)
  }, [conversation])

  useEffect(() => {
    const report = () =>
      api.action(PageAction, { page, focused: focusedNow(), conversation, draft }).catch(() => undefined)
    void report()
    if (!focused) return
    const timer = window.setInterval(report, heartbeat)
    return () => window.clearInterval(timer)
  }, [conversation, focused, draft])

  useEffect(() => {
    if (!focused || !draft) return
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
        const before = draftOf(ask.conversation)
        const { sent } = await api
          .action(ComposedAction, { id: ask.id, page, draft: before })
          .catch(() => ({ sent: false }))
        if (sent && draftOf(ask.conversation) === before) fillComposer(ask.conversation, '')
      }
    })()
    return () => controller.abort()
  }, [focused, draft])

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
