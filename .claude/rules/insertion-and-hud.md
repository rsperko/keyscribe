---
paths:
  - "Sources/KeyScribe/Adapters/TextInserter.swift"
  - "Sources/KeyScribe/HUD/*.swift"
  - "Sources/KeyScribe/{CorrectionPanelController,HistoryController}.swift"
  - "Sources/KeyScribeKit/ClipboardKeystroke.swift"
  - "Tests/**/{PasteboardSnapshot,TextInserter,HUDState,ClipboardKeystroke}*.swift"
---

You are working in code that touches insertion, the pasteboard, or HUD focus. Before editing, open `docs/development/areas/insertion-and-hud.md`, scan its section headings, and read every section that covers the code you are changing. If the change spans more than one section, read the whole guide. Several of its rules fail silently.
