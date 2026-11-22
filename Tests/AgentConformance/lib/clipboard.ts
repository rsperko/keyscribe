import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { run } from "./util.ts"

const helper = join(dirname(fileURLToPath(import.meta.url)), "..", "clipboard.swift")

export function clipboard(...args: string[]) {
  const answer = run("xcrun", ["swift", helper, ...args], { timeout: 60 })
  if (answer.status !== 0) throw new Error(`clipboard ${args[0]} failed: ${answer.stdout}${answer.stderr}`)
}

export async function withClipboard<T>(work: () => Promise<T>): Promise<T> {
  const folder = mkdtempSync(join(tmpdir(), "keyscribe-clipboard-"))
  const saved = join(folder, "saved.plist")
  clipboard("save", saved)
  try {
    return await work()
  } finally {
    try { clipboard("restore", saved) } finally { rmSync(folder, { recursive: true, force: true }) }
  }
}
