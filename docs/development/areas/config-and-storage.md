# Config storage and migrations

Read before changing any on-disk config store, `schema_version` handling, or a migration.

## Storage

- **A write never loses what it did not edit.** Every save re-reads the on-disk file at write time and
  keeps unedited fields; a file holding keys the app does not read refuses the save
  (`ConfigRepository.refuseUnreadKeys`) rather than dropping them. A migration never overwrites a
  deliberate user choice (an exclusion, an override). A file that fails to read or decode is an error,
  never treated as absent and replaced.

Config lives under `~/Library/Application Support/<KeyScribe|KeyScribeDev>/` (per variant; the
`models/` weights cache is shared), loaded once into `ConfigCache` and invalidated by an FSEvents
watcher (no per-dictation I/O). File-based storage, **no SQLite**: config
as TOML (modes/connections/dictionary/replacements), fragments as markdown+YAML, history as
JSONL-per-day, downloaded STT weights consolidated in `models/` (`docs/reference/config_schema.md`). Every persisted
*config* file carries `schema_version`; older versions are normalized on read (`docs/development/design.md` §5.1);
`models/` is runtime-downloaded, never committed.

**Config migrations — two mechanisms; know which one a store uses.** `ConfigDecode.table` gates
versions (it rejects a file newer than the app) and, when a store passes `migrations:`, runs
`MigrationRunner`: ordered `MigrationStep`s chained from the file's `schema_version` up to the current
one, each transforming the parsed table before decode (`ModeStore.migrations` is the in-tree example).
`MigrationStep`/`MigrationRunner.migrate` and that `migrations:` hook are **public API a downstream build
uses for its own schema history** — keep them even when no in-tree store has steps. A store without
steps relies on additive `decodeIfPresent ?? default` instead. Consequences a future migration must
respect: (1) either way it is an **idempotent read transform** re-run on **every** load, never a
recorded one-shot — an old file stays its old version on disk until something rewrites it; (2) steps
chain, so a step only handles its own `from` version, but a store **without** steps needs its current
decoder to understand every still-supported old version directly; (3) **removing a field** costs one
line: the key is ignored on read and dropped on the next write (how `default_mode_id` was retired), but
an unread key is reported to the user as having no effect — list the retired key in the store's retired
keys (`SettingsStore.retiredKeys`; give a store that has none a set of its own) or every old file warns. Where a migration genuinely must run **once** (e.g. the
Plain-Dictation→Direct replacement in `ModeStore.ensureSystemModes`), it keys off a durable artifact —
the presence of `_direct.toml` — as its marker, which means **it will not re-run**. If you add a
one-shot migration that must re-run after a later change, that file-presence marker is *not* enough; add
an explicit migration flag (e.g. in the seed ledger) instead.
