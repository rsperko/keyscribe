import { existsSync, mkdirSync, openSync, closeSync, readSync, readdirSync, statSync, writeFileSync } from "node:fs"
import { join } from "node:path"

export const caseKey = (name: string) => name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")

export function tail(path: string, limit = 512 * 1024) {
  const fd = openSync(path, "r")
  try {
    const size = statSync(path).size
    const buffer = Buffer.alloc(Math.min(size, limit))
    const count = readSync(fd, buffer, 0, buffer.length, Math.max(0, size - buffer.length))
    return buffer.subarray(0, count)
  } finally { closeSync(fd) }
}

export async function failureBundle(
  instance: string, label: string, error: unknown,
  readers: Record<string, () => unknown | Promise<unknown>> = {},
) {
  const base = process.env.KEYSCRIBE_VERIFICATION_ARTIFACTS ?? join(instance, "failures")
  const folder = join(base, `${caseKey(label)}-${Date.now()}`)
  mkdirSync(folder, { recursive: true, mode: 0o700 })
  writeFileSync(join(folder, "failure.json"), JSON.stringify({ case: label, at: new Date().toISOString(), error: String(error),
    stack: error instanceof Error ? error.stack : undefined, instance }, null, 2))
  for (const name of ["app.log", "conformance.json", "scripted-reads.jsonl"]) {
    const path = join(instance, name)
    if (existsSync(path)) writeFileSync(join(folder, name), tail(path))
  }
  const history = join(instance, "history")
  if (existsSync(history)) {
    const files = readdirSync(history).filter(name => name.endsWith(".jsonl")).sort().slice(-2)
    for (const name of files) writeFileSync(join(folder, `history-${name}`), tail(join(history, name)))
  }
  for (const [name, read] of Object.entries(readers)) {
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const value = await Promise.race([
        Promise.resolve().then(read),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("diagnostic reader timed out after 15s")), 15_000) }),
      ])
      if (value === undefined) writeFileSync(join(folder, `${caseKey(name)}.txt`), "nothing to show")
      else if (value instanceof Uint8Array) writeFileSync(join(folder, `${caseKey(name)}.png`), value)
      else writeFileSync(join(folder, `${caseKey(name)}.json`), JSON.stringify(value, null, 2))
    }
    catch (failure) { writeFileSync(join(folder, `${caseKey(name)}.error.txt`), String(failure)) }
    finally { clearTimeout(timer) }
  }
  console.log(`Failure bundle: ${folder}`)
  return folder
}
