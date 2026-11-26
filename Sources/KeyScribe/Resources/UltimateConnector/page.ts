import { automatedBrowser, composerProblem, typesText, typingTarget } from './keyscribe.ts'

export const heartbeat = 5000

export function visible(editor: HTMLElement): boolean {
  return editor.getClientRects().length > 0 && !editor.closest('[inert], [aria-hidden="true"]')
}

export function editorOf(conversation: number): HTMLTextAreaElement | undefined {
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

function shownEditors(): HTMLTextAreaElement[] {
  return [...document.querySelectorAll<HTMLTextAreaElement>('textarea[data-conversation]')].filter(visible)
}

export function composerNow(shown: number | null = null, home = true, drawn = shownEditors()): {
  conversation: number | null; draft: boolean; newConversation?: boolean; parent?: number; pageConversation: number | null; problem?: string
} {
  const editors = drawn.filter(editor => !editor.disabled && !editor.readOnly)
  const blocked = [...document.querySelectorAll<HTMLElement>('[role="dialog"], [role="alertdialog"], dialog[open]')].some(visible)
  const focus = document.activeElement as HTMLElement | null
  const elsewhere = typesText(focus) && !editors.some(editor => editor === focus)
  const target = typingTarget(editors.map(editor => ({
    id: Number(editor.dataset.conversation),
    active: document.activeElement === editor,
    sideMode: editor.closest('[data-side-mode="side"]') !== null,
  })), blocked, elsewhere)
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
  const conversation = !blocked && !elsewhere && home && editors.length === 0 ? shown : null
  return {
    conversation,
    draft: false,
    pageConversation,
    problem: composerProblem({ blocked, elsewhere, editors: editors.length, home }),
  }
}

export function draftOf(conversation: number): string {
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

export function subscribe(listener: () => void) {
  let focus = document.activeElement
  const notify = () => {
    focus = document.activeElement
    listener()
  }
  for (const name of focusEvents) window.addEventListener(name, notify, true)
  const observer = new MutationObserver((records) => {
    if (document.activeElement !== focus || touchesComposer(records)) notify()
  })
  observer.observe(document.body, { childList: true, subtree: true, attributes: true,
    attributeFilter: ['inert', 'hidden', 'aria-hidden', 'disabled', 'readonly', 'open', 'data-conversation', 'data-side-mode'] })
  const reread = window.setInterval(() => {
    if (document.visibilityState === 'visible') notify()
  }, heartbeat)
  return () => {
    for (const name of focusEvents) window.removeEventListener(name, notify, true)
    observer.disconnect()
    window.clearInterval(reread)
  }
}
const automated = automatedBrowser(navigator)
export const focusedNow = () => !automated && document.visibilityState === 'visible' && document.hasFocus()
export type Shown = {
  conversation: number | null; draft: boolean; newConversation?: boolean; parent?: number; pageConversation: number | null; problem?: string; focused: boolean
}

export function labelsWanted(shown: number | null, drawn = shownEditors()): number[] {
  const ids = drawn.map(editor => Number(editor.dataset.conversation)).filter(id => Number.isSafeInteger(id) && id > 0)
  return [...new Set(shown === null ? ids : [shown, ...ids])]
}

export type PageNow = Shown & { labelsOf: number[] }

export function pageNow(shown: number | null, home: boolean): PageNow {
  const drawn = shownEditors()
  return {
    ...composerNow(shown, home, drawn), focused: focusedNow(), labelsOf: labelsWanted(shown, drawn),
  }
}

export function reportOf(now: PageNow): Shown {
  const report: Partial<PageNow> = { ...now }
  delete report.labelsOf
  return report as Shown
}

let labels: Record<string, string> = {}
const labelListeners = new Set<() => void>()

export function showLabels(next: Record<string, string> | undefined) {
  const value = next ?? {}
  if (JSON.stringify(value) === JSON.stringify(labels)) return
  labels = value
  for (const listener of labelListeners) listener()
}

export function labelsFor(ids: number[]): Record<string, string> {
  return Object.fromEntries(ids.filter(id => labels[String(id)] !== undefined).map(id => [String(id), labels[String(id)]]))
}

export function labelOf(conversation: number | null): string | null {
  return conversation === null ? null : labels[String(conversation)] ?? null
}

export function subscribeLabels(listener: () => void) {
  labelListeners.add(listener)
  return () => { labelListeners.delete(listener) }
}

export const retryPause = 2000
export const retryLimit = 10000

type Labels = Record<string, string>

export type Reporting<Ask> = {
  report: Shown
  labelsOf: number[]
  signal: AbortSignal
  tell: (labelsOf: number[]) => Promise<{ labels?: Labels }>
  ask: (asking: boolean, labelsOf: number[], labels: Labels) => Promise<{ ask: Ask | null; labels?: Labels }>
  handle: (ask: Ask) => Promise<void>
}

const later = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms))

export async function keepReporting<Ask>({ report, labelsOf, signal, tell, ask, handle }: Reporting<Ask>) {
  const asking = report.focused && (report.draft || report.newConversation === true)
  let pause = retryPause
  while (!signal.aborted) {
    let given: Ask | null = null
    try {
      if (report.focused) {
        const answer = await ask(asking, labelsOf, labelsFor(labelsOf))
        if (signal.aborted) return
        showLabels(answer.labels)
        given = answer.ask
      } else {
        const answer = await tell(labelsOf)
        if (!signal.aborted) showLabels(answer.labels)
        return
      }
      pause = retryPause
    } catch {
      if (signal.aborted) return
      await later(pause)
      pause = Math.min(pause * 2, retryLimit)
      continue
    }
    if (given && asking && !signal.aborted) await handle(given)
  }
}
