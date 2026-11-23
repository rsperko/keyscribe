import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { markKept, scratchPrefixes } from "./scratch.ts"
import { run, sleep } from "./util.ts"

export type Message = { role: "user" | "agent" | "ended"; text: string; turn?: string; mark?: string }
export type Shown = { thread: boolean; focused: boolean; draft: string | null }

export type ListedWindow = { app: string; spec: string; title: string }

export interface AppWindow {
  owns(window: ListedWindow): boolean
  readonly reopens: boolean
  readonly takeBehindDraft: "kept" | "sent"
  readonly app?: string
  focus?(): Promise<void>
  show(): Promise<void>
  look(): Promise<Shown>
  fill(text: string): Promise<void>
  close(): Promise<void>
}

export interface AgentDriver {
  readonly kind: string
  readonly name: string
  readonly folder: string
  readonly project: string
  readonly tool: string | undefined
  readonly conversation: string | undefined
  readonly addresses?: { said: string; absent: string }
  readonly window?: AppWindow
  owns(conversation: string | undefined): boolean
  setUp(): Promise<void>
  start(): Promise<void>
  idle(seconds: number): Promise<void>
  messages(): Promise<Message[]>
  stop(keep: boolean): Promise<void>
  untouched?(): string[]
  noteFromHost?(): Promise<void>
  interrupt?(): Promise<void>
  readonly server?: { stop(): Promise<void>; start(): Promise<void> }
  diagnostics?(): Record<string, () => unknown | Promise<unknown>>
}

export function scratch(name: string) {
  const root = realpathSync(mkdtempSync(`/tmp/${scratchPrefixes.agent}`))
  const project = join(root, name)
  mkdirSync(project)
  run("git", ["init", "-q", project])
  writeFileSync(join(project, "README.md"), "A scratch project for KeyScribe's agent conformance run.\n")
  return { root, project }
}

export function command(name: string, variable: string): string {
  const chosen = process.env[variable] ?? run("/bin/zsh", ["-lc", `command -v ${name}`]).stdout.trim()
  if (!chosen) throw new Error(`${name} is not installed (or set ${variable} to its path)`)
  return chosen
}

export async function settled(read: () => Promise<Message[]>, seconds: number) {
  const end = Date.now() + seconds * 1000
  let last = ""
  let steady = 0
  while (Date.now() < end) {
    const messages = await read()
    const now = JSON.stringify(messages)
    steady = now === last && messages.at(-1)?.role !== "user" ? steady + 1 : 0
    if (steady >= 3) return
    last = now
    await sleep(1000)
  }
  throw new Error(`the conversation did not settle within ${seconds} s`)
}

export function removeScratch(root: string, keep: boolean) {
  run("/usr/bin/pkill", ["-f", root])
  if (keep) markKept(root)
  else rmSync(root, { recursive: true, force: true })
}
