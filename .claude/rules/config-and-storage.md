---
paths:
  - "Sources/KeyScribeKit/{ConfigDecode,MigrationRunner,FragmentStore,HistoryStore,AppVariant,Mode,ModeSeedReconcile,Settings}.swift"
  - "Sources/KeyScribe/Adapters/{ConfigCache,ConfigWatcher,KeyScribePaths,KeychainStore}.swift"
  - "Sources/KeyScribe/ConfigRepository.swift"
  - "Tests/**/{MigrationRunner,ConfigCache,ConfigWatcher,ModeStore,AppVariant}*.swift"
---

You are working in code that touches config storage or migrations. Before editing, open `docs/development/areas/config-and-storage.md`, scan its section headings, and read every section that covers the code you are changing. If the change spans more than one section, read the whole guide. Several of its rules fail silently.
