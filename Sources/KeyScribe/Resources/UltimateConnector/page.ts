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

export function composerNow(shown: number | null = null, home = true): {
  conversation: number | null; draft: boolean; newConversation?: boolean; parent?: number; pageConversation: number | null; problem?: string
} {
  const editors = [...document.querySelectorAll<HTMLTextAreaElement>('textarea[data-conversation]')]
    .filter(editor => visible(editor) && !editor.disabled && !editor.readOnly)
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
