import AppKit
import KeyScribeKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    // contentTintColor on a status-bar button renders black since Big Sur
    // (developer.apple.com/forums/thread/666539), so tinted states use a pre-colored, non-template
    // glyph instead. The template variant (color nil) keeps adaptive black/white for production idle.
    static func glyph(color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            (color ?? .black).setStroke()

            let pulse = NSBezierPath()
            pulse.lineWidth = 1.6
            pulse.lineCapStyle = .round
            pulse.lineJoinStyle = .round
            pulse.move(to: NSPoint(x: 1.6, y: 9))
            pulse.curve(
                to: NSPoint(x: 3.4, y: 12.7),
                controlPoint1: NSPoint(x: 2.2, y: 9.1),
                controlPoint2: NSPoint(x: 2.6, y: 12.6)
            )
            pulse.curve(
                to: NSPoint(x: 5.2, y: 5),
                controlPoint1: NSPoint(x: 4.3, y: 12.8),
                controlPoint2: NSPoint(x: 4.3, y: 5)
            )
            pulse.curve(
                to: NSPoint(x: 7, y: 16.2),
                controlPoint1: NSPoint(x: 6.1, y: 5),
                controlPoint2: NSPoint(x: 5.9, y: 16.2)
            )
            pulse.curve(
                to: NSPoint(x: 9.2, y: 2),
                controlPoint1: NSPoint(x: 8.2, y: 16.2),
                controlPoint2: NSPoint(x: 7.8, y: 2)
            )
            pulse.stroke()

            for (y, endX) in [(11.4, 14.6), (6.6, 15.3)] {
                let line = NSBezierPath()
                line.lineWidth = 1.75
                line.lineCapStyle = .round
                line.move(to: NSPoint(x: 10.5, y: y))
                line.line(to: NSPoint(x: endX, y: y))
                line.stroke()
            }

            return true
        }
        image.isTemplate = color == nil
        return image
    }

    static let statusIcon: NSImage = glyph(color: nil)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: "Paste Last Dictation", action: nil, keyEquivalent: "")
    private let addVocabularyItem = NSMenuItem(title: "Add to Vocabulary…", action: nil, keyEquivalent: "")
    private let speechModelsMenu = NSMenu()
    private let modesMenu = NSMenu()

    private let badgeDot: NSView = {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        return dot
    }()

    // Passive "update available" affordance — only rendered when an injected updater reports one.
    // A separate colored layer (top-right) so it is distinct from the top-left error badge.
    private let updateDot: NSView = {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        return dot
    }()
    private let updateItem = NSMenuItem(title: "Update…", action: nil, keyEquivalent: "")
    private var appMenu: NSMenu?

    var onPasteLast: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSpeechModels: (() -> Void)?
    var onOpenModes: (() -> Void)?
    var onOpenNotices: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?
    var onSelectNextMode: ((String?) -> Void)?
    var onSelectSpeechModel: ((String) -> Void)?
    var onAddVocabulary: (() -> Void)?
    var onUpdate: (() -> Void)?

    private let variant = KeyScribePaths.variant
    private static let devTint = NSColor.systemOrange
    private static let recordingIcon = glyph(color: .systemRed)
    private static let devIcon = glyph(color: devTint)

    private var idleIcon: NSImage { variant.isDev ? Self.devIcon : Self.statusIcon }

    func install() {
        if let button = statusItem.button {
            button.image = idleIcon
            button.image?.accessibilityDescription = variant.displayName
            button.addSubview(badgeDot)
            button.addSubview(updateDot)
            NSLayoutConstraint.activate([
                badgeDot.widthAnchor.constraint(equalToConstant: 6),
                badgeDot.heightAnchor.constraint(equalToConstant: 6),
                badgeDot.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
                badgeDot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
                updateDot.widthAnchor.constraint(equalToConstant: 6),
                updateDot.heightAnchor.constraint(equalToConstant: 6),
                updateDot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                updateDot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            ])
        }
        let menu = NSMenu()
        appMenu = menu
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let speechModel = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        speechModel.submenu = speechModelsMenu
        menu.addItem(speechModel)

        let dictateWith = NSMenuItem(title: "Dictate with", action: nil, keyEquivalent: "")
        dictateWith.submenu = modesMenu
        menu.addItem(dictateWith)

        menu.addItem(.separator())
        pasteLastItem.target = self
        pasteLastItem.action = #selector(pasteLast)
        pasteLastItem.isEnabled = false
        menu.addItem(pasteLastItem)

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "y")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())
        addVocabularyItem.target = self
        addVocabularyItem.action = #selector(addVocabulary)
        menu.addItem(addVocabularyItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let notices = NSMenuItem(title: "About & Notices…", action: #selector(openNotices), keyEquivalent: "")
        notices.target = self
        menu.addItem(notices)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(Branding.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen?() }

    func setStatus(_ text: String) { statusLine.title = text }
    func setHasResult(_ hasResult: Bool) { pasteLastItem.isEnabled = hasResult }

    func setSpeechModels(_ rows: [SpeechModelsModel.Row]) {
        speechModelsMenu.removeAllItems()
        for row in rows where row.isUsable {
            let item = NSMenuItem(title: row.info.displayName, action: #selector(selectSpeechModel), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.state = row.isActive ? .on : .off
            speechModelsMenu.addItem(item)
        }
        if speechModelsMenu.items.isEmpty {
            let empty = NSMenuItem(title: "No usable speech models", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            speechModelsMenu.addItem(empty)
        }
        speechModelsMenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Speech Models…", action: #selector(openSpeechModels), keyEquivalent: "")
        manage.target = self
        speechModelsMenu.addItem(manage)
    }

    // Mirror the active (non-shadowed, chord-only) global shortcuts onto the menu items as a
    // right-aligned glyph. Nil clears it — unset or shadowed shouldn't advertise a shortcut.
    func setActionShortcuts(addVocabulary: KeyDescriptor?, pasteLast: KeyDescriptor?) {
        apply(addVocabulary, to: addVocabularyItem)
        apply(pasteLast, to: pasteLastItem)
    }

    private func apply(_ descriptor: KeyDescriptor?, to item: NSMenuItem) {
        if let (key, modifiers) = descriptor?.menuItemKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    // Swap to the red glyph while capture is active (ui_design.md §Dynamic status — recording
    // reflects that capture is active); reverts to the idle glyph on commit. A swapped non-template
    // image is used rather than contentTintColor, which renders black on a status-bar button.
    func setDictating(_ active: Bool) {
        let image = active ? Self.recordingIcon : idleIcon
        image.accessibilityDescription = variant.displayName
        statusItem.button?.image = image
    }

    // The error badge — a small red dot, top-left (ui_design.md §6) — for a configuration, model, or
    // permission problem. A separate colored layer so it survives the recording tint and the template
    // glyph's appearance adaptation.
    func setErrorBadge(_ visible: Bool) { badgeDot.isHidden = !visible }

    // Inert by default: with no updater injected this is never called, so no dot and no menu item
    // render. When set, a passive dot appears on the glyph and an "Update…" item is added to the menu.
    func setUpdateAvailable(_ available: Bool) {
        updateDot.isHidden = !available
        guard let appMenu else { return }
        let present = appMenu.items.contains(updateItem)
        if available, !present {
            updateItem.target = self
            updateItem.action = #selector(triggerUpdate)
            appMenu.insertItem(updateItem, at: 0)
        } else if !available, present {
            appMenu.removeItem(updateItem)
        }
    }

    func setModes(
        _ modes: [Mode], automaticName: String?, overrideName: String?,
        inertReasons: [String: String] = [:]
    ) {
        modesMenu.removeAllItems()
        let automatic = NSMenuItem(title: "Automatic\(automaticName.map { " — \($0)" } ?? "")", action: #selector(selectAutomatic), keyEquivalent: "")
        automatic.target = self
        automatic.state = overrideName == nil ? .on : .off
        modesMenu.addItem(automatic)
        modesMenu.addItem(.separator())
        for mode in modes {
            // A rewrite-using starter mode stays listed but inert until its AI service exists, and
            // says so in place rather than disappearing (ui_design.md §6).
            let reason = inertReasons[mode.id]
            let title = reason.map { "\(mode.name) — \($0)" } ?? mode.name
            let item = NSMenuItem(
                title: title, action: reason == nil ? #selector(selectMode) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.isEnabled = reason == nil
            item.state = overrideName == mode.name ? .on : .off
            modesMenu.addItem(item)
        }
        modesMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Applies to the next dictation only", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        modesMenu.addItem(hint)
        let manage = NSMenuItem(title: "Manage Modes…", action: #selector(openModes), keyEquivalent: "")
        manage.target = self
        modesMenu.addItem(manage)
    }

    @objc private func pasteLast() { onPasteLast?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openSpeechModels() { onOpenSpeechModels?() }
    @objc private func openModes() { onOpenModes?() }
    @objc private func openNotices() { onOpenNotices?() }
    @objc private func selectAutomatic() { onSelectNextMode?(nil) }
    @objc private func selectMode(_ sender: NSMenuItem) { onSelectNextMode?(sender.representedObject as? String) }
    @objc private func selectSpeechModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectSpeechModel?(id)
    }
    @objc private func addVocabulary() { onAddVocabulary?() }
    @objc private func triggerUpdate() { onUpdate?() }
}
