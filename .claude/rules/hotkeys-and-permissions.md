---
paths:
  - "Sources/KeyScribe/Adapters/{HotkeyMonitor,CarbonHotKeys,MouseEventTap,KeyboardLayout,AccessibilityRecovery,Permissions}.swift"
  - "Sources/KeyScribe/{ResetTool,KeyDescriptor+MenuItem}.swift"
  - "Sources/KeyScribe/Settings/{HotkeyRecorder,PermissionsSettingsView,ShortcutMoveCopy}.swift"
  - "Sources/KeyScribeKit/{KeyDescriptor,KeyboardLayoutIndex,ModeResolver,ShortcutCapture,TriggerKeyConflict,ClipboardKeystroke}.swift"
  - "Tests/**/{Hotkey,KeyDescriptor,KeyboardLayout,TriggerKeyConflict,ModeResolver,Shortcut,AccessibilityRecovery,ResetTool}*.swift"
---

You are working in code that touches hotkeys, triggers, and permissions. Before editing, open `docs/development/areas/hotkeys-and-permissions.md`, scan its section headings, and read every section that covers the code you are changing. If the change spans more than one section, read the whole guide. Several of its rules fail silently.
