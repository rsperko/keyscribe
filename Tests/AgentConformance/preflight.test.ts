import assert from "node:assert/strict"
import { test } from "node:test"
import { inputUnseen, startingApp } from "./lib/preflight.ts"

const tree: Record<number, { parent: number; command: string }> = {
  40: { parent: 30, command: "node" },
  30: { parent: 20, command: "/bin/zsh" },
  20: { parent: 10, command: "/Applications/Some Agent.app/Contents/MacOS/agent" },
  10: { parent: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty" },
}

test("the app a run was started from is the outermost app above it, the one macOS charges for the instance's Accessibility", () => {
  assert.equal(startingApp(40, (pid) => tree[pid]), "/Applications/Ghostty.app")
  assert.equal(startingApp(30, (pid) => (pid === 30 ? { parent: 1, command: "/bin/zsh" } : undefined)), undefined)
})

test("the Accessibility message names the app that started the run, not only the app under test", () => {
  const message = inputUnseen("/x/KeyScribeDev.app/Contents/MacOS/KeyScribe", "/Applications/Ghostty.app")
  assert.match(message, /charges a test instance's Accessibility to the app this run was started from, \/Applications\/Ghostty\.app, not to \/x\/KeyScribeDev\.app/)
  assert.match(inputUnseen("/x/KeyScribeDev.app/Contents/MacOS/KeyScribe", null), /the terminal or app this run was started from/)
})
