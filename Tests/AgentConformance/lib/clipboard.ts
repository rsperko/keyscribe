import { createHash } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { run } from "./util.ts"

const source = join(dirname(fileURLToPath(import.meta.url)), "..", "clipboard.swift")
let compiled: string | undefined

function helper() {
  if (compiled) return compiled
  const folder = join(tmpdir(), "keyscribe-clipboard-helper")
  const binary = join(folder, createHash("sha256").update(readFileSync(source)).digest("hex").slice(0, 16))
  if (!existsSync(binary)) {
    mkdirSync(folder, { recursive: true })
    const building = `${binary}.${process.pid}`
    const built = run("xcrun", ["swiftc", "-O", source, "-o", building], { timeout: 180 })
    if (built.status !== 0) throw new Error(`the clipboard helper did not compile: ${built.stdout}${built.stderr}`)
    renameSync(building, binary)
  }
  return compiled = binary
}

export function clipboard(...args: string[]) {
  const answer = run(helper(), args, { timeout: 30 })
  if (answer.status !== 0) throw new Error(`clipboard ${args[0]} failed: ${answer.stdout}${answer.stderr}`)
}

export type ClipboardMark = () => () => boolean

export async function withClipboard<T>(work: (mark: ClipboardMark) => Promise<T>): Promise<T> {
  const folder = mkdtempSync(join(tmpdir(), "keyscribe-clipboard-"))
  const saved = join(folder, "saved.plist")
  let marks = 0
  const mark = () => {
    const marked = join(folder, `mark${++marks}.plist`)
    clipboard("save", marked)
    return () => {
      const answer = run(helper(), ["same", marked], { timeout: 30 })
      if (answer.status === 3) return false
      if (answer.status !== 0) throw new Error(`clipboard same failed: ${answer.stdout}${answer.stderr}`)
      return true
    }
  }
  try {
    clipboard("save", saved)
    return await work(mark)
  } finally {
    try { if (existsSync(saved)) clipboard("restore", saved) } finally { rmSync(folder, { recursive: true, force: true }) }
  }
}
