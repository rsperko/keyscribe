import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export const scratchPrefixes = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "scratch-prefixes.json"), "utf8")) as {
  instance: string
  agent: string
  keptMarker: string
}

export function markKept(folder: string) {
  if (existsSync(folder)) writeFileSync(join(folder, scratchPrefixes.keptMarker), "")
}
