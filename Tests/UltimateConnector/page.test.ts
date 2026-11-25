import assert from "node:assert/strict"
import { test } from "node:test"

const listeners = new Map<string, Set<() => void>>()
let observed: ((records: unknown[]) => void) | null = null
const body = { tagName: "BODY" }
const fake = { activeElement: body as unknown, body, visibilityState: "hidden", hasFocus: () => false }
Object.assign(globalThis, {
  Element: class {},
  document: fake,
  window: {
    addEventListener: (name: string, listener: () => void) => {
      if (!listeners.has(name)) listeners.set(name, new Set())
      listeners.get(name)!.add(listener)
    },
    removeEventListener: (name: string, listener: () => void) => listeners.get(name)?.delete(listener),
    setInterval: () => 1,
    clearInterval: () => undefined,
  },
  MutationObserver: class {
    constructor(callback: (records: unknown[]) => void) { observed = callback }
    observe() {}
    disconnect() {}
  },
})
const { subscribe } = await import("../../Sources/KeyScribe/Resources/UltimateConnector/page.ts")

const fire = (name: string) => { for (const listener of listeners.get(name) ?? []) listener() }
const removed = (node: unknown) => [{ type: "childList", addedNodes: [], removedNodes: [node] }]

test("a focused box removed without a blur still re-reads the page", () => {
  let reads = 0
  const stop = subscribe(() => { reads++ })
  const note = { tagName: "TEXTAREA" }
  fake.activeElement = note
  fire("focusin")
  const afterFocus = reads
  fake.activeElement = body
  observed!(removed(note))
  assert.equal(reads, afterFocus + 1, "the removal moved focus, so the page must be read again")
  observed!(removed({ tagName: "DIV" }))
  assert.equal(reads, afterFocus + 1, "a change that moves no focus and touches no composer reads nothing")
  stop()
})
