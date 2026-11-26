import assert from "node:assert/strict"
import { test } from "node:test"

const listeners = new Map<string, Set<() => void>>()
const pauses: number[] = []
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
    setTimeout: (fn: () => void, ms: number) => { pauses.push(ms); queueMicrotask(fn); return 1 },
  },
  MutationObserver: class {
    constructor(callback: (records: unknown[]) => void) { observed = callback }
    observe() {}
    disconnect() {}
  },
})
const { keepReporting, labelOf, labelsFor, labelsWanted, showLabels, subscribe, subscribeLabels } = await import("../../Sources/KeyScribe/Resources/UltimateConnector/page.ts")

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

test("the names a page report brings back are shown until a later report drops them, and only a change redraws", () => {
  let redraws = 0
  const stop = subscribeLabels(() => { redraws++ })
  showLabels({ "61": "login fix" })
  showLabels({ "61": "login fix" })
  assert.equal(labelOf(61), "login fix")
  assert.equal(labelOf(53), null)
  assert.equal(redraws, 1)
  showLabels(undefined)
  assert.equal(labelOf(61), null)
  assert.equal(redraws, 2)
  stop()
})

test("the conversation shown is asked about first, so a cap on the names asked never drops it", () => {
  const box = (conversation: string) => ({ dataset: { conversation } }) as unknown as HTMLTextAreaElement
  assert.deepEqual(labelsWanted(61, [box("53"), box("61"), box("x")]), [61, 53])
  assert.deepEqual(labelsWanted(null, [box("53")]), [53])
})

test("a held request carries the names the page already shows for what it asks about", () => {
  showLabels({ "61": "login fix", "53": "release" })
  assert.deepEqual(labelsFor([61, 70]), { "61": "login fix" })
  showLabels({})
})

const focusedReport = { conversation: 61, draft: false, pageConversation: 61, focused: true }

test("a focused page's held request backs off on failures up to a short cap, and starts over after an answer", async () => {
  pauses.length = 0
  const controller = new AbortController()
  const outcomes = ["fail", "fail", "fail", "fail", "fail", "ok", "fail", "stop"]
  const handled: unknown[] = []
  await keepReporting({
    report: focusedReport, labelsOf: [61], signal: controller.signal,
    tell: async () => { throw new Error("a focused page never only reports") },
    ask: async () => {
      const outcome = outcomes.shift()
      if (outcome === "stop") controller.abort()
      if (outcome !== "ok") throw new Error("unreachable")
      return { ask: { id: "a" }, labels: { "61": "login fix" } }
    },
    handle: async (ask) => { handled.push(ask) },
  })
  assert.deepEqual(pauses, [2000, 4000, 8000, 10000, 10000, 2000])
  assert.equal(labelOf(61), "login fix")
  assert.deepEqual(handled, [], "a page not asking for a dictation never handles one")
  showLabels({})
})

test("a page without focus reports once, retrying a report that fails, and shows the names its answer carries", async () => {
  pauses.length = 0
  let tells = 0
  await keepReporting({
    report: { ...focusedReport, focused: false }, labelsOf: [61], signal: new AbortController().signal,
    tell: async () => {
      tells++
      if (tells < 3) throw new Error("unreachable")
      return { labels: { "61": "login fix" } }
    },
    ask: async () => { throw new Error("only the focused page holds a request") },
    handle: async () => {},
  })
  assert.equal(tells, 3)
  assert.deepEqual(pauses, [2000, 4000])
  assert.equal(labelOf(61), "login fix")
  showLabels({})
})
