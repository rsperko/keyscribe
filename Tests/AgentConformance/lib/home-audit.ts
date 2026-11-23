import { createHash } from "node:crypto"
import { lstatSync, readdirSync, readFileSync, readlinkSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { basename, join } from "node:path"

export const watchedInHome = [
  ".codex/config.toml",
  ".codex/hooks.json",
  ".claude/settings.json",
  ".claude/plugins/installed_plugins.json",
  ".claude/plugins/known_marketplaces.json",
  ".pi/agent/settings.json",
  ".pi/agent/extensions",
  ".omp/agent/config.yml",
  ".omp/agent/extensions",
  ".ultimate/settings.json",
  ".ultimate/extensions",
]

export type HomeSnapshot = Map<string, string>

const unread = new Set([".git", "node_modules"])
export const auditLimit = 20_000

const digest = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex")

function walk(path: string, into: HomeSnapshot) {
  const stat = lstatSync(path, { throwIfNoEntry: false })
  if (!stat) return
  if (into.size >= auditLimit) throw new Error(`more than ${auditLimit} files under the folders it compares, at ${path}`)
  if (stat.isSymbolicLink()) {
    const target = statSync(path, { throwIfNoEntry: false })
    const contents = target?.isFile() ? `, ${digest(path)}` : ""
    into.set(path, `link to ${readlinkSync(path)}${contents}`)
  } else if (stat.isDirectory()) {
    into.set(`${path}/`, "folder")
    if (unread.has(basename(path))) return
    for (const name of readdirSync(path).sort()) walk(join(path, name), into)
  } else if (stat.isFile()) {
    into.set(path, digest(path))
  }
}

export function snapshotHome(home = homedir(), watched = watchedInHome): HomeSnapshot {
  const snapshot: HomeSnapshot = new Map()
  try {
    for (const relative of watched) walk(join(home, relative), snapshot)
  } catch (error) {
    throw new Error(`could not record the agents' files in your home folder to check the run leaves them alone: ${(error as Error).message}`)
  }
  return snapshot
}

export function homeChanges(before: HomeSnapshot, after: HomeSnapshot): string[] {
  const changes: string[] = []
  for (const [path, digest] of before) {
    if (!after.has(path)) changes.push(`removed ${path}`)
    else if (after.get(path) !== digest) changes.push(`changed ${path}`)
  }
  for (const path of after.keys()) if (!before.has(path)) changes.push(`added ${path}`)
  return changes
}
