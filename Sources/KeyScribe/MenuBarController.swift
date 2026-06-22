import AppKit
import KeyScribeKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let statusIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            for (x, lower, upper) in [(2.5, 7.5, 10.5), (5, 5.5, 12.5), (7.5, 3, 15)] {
                let pulse = NSBezierPath()
                pulse.lineWidth = 1.75
                pulse.lineCapStyle = .round
                pulse.move(to: NSPoint(x: x, y: lower))
                pulse.line(to: NSPoint(x: x, y: upper))
                pulse.stroke()
            }

            for (y, endX) in [(11.5, 15), (6.5, 16.5)] {
                let line = NSBezierPath()
                line.lineWidth = 1.75
                line.lineCapStyle = .round
                line.move(to: NSPoint(x: 11, y: y))
                line.line(to: NSPoint(x: endX, y: y))
                line.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Status: starting…", action: nil, keyEquivalent: "")
    private let nextModeLine = NSMenuItem(title: "Next dictation: Automatic", action: nil, keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: "Paste Last Dictation", action: nil, keyEquivalent: "")
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

    var onPasteLast: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenNotices: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?
    var onSelectNextMode: ((String?) -> Void)?
    var onAddDictionaryEntry: (() -> Void)?
    var onAddReplacement: (() -> Void)?

    func install() {
        if let button = statusItem.button {
            button.image = Self.statusIcon
            button.image?.accessibilityDescription = "KeyScribe"
            button.addSubview(badgeDot)
            NSLayoutConstraint.activate([
                badgeDot.widthAnchor.constraint(equalToConstant: 6),
                badgeDot.heightAnchor.constraint(equalToConstant: 6),
                badgeDot.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 1),
                badgeDot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            ])
        }
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        nextModeLine.isEnabled = false
        menu.addItem(nextModeLine)

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
        let addDictionary = NSMenuItem(title: "Add Dictionary Entry…", action: #selector(addDictionaryEntry), keyEquivalent: "")
        addDictionary.target = self
        menu.addItem(addDictionary)
        let addReplacement = NSMenuItem(title: "Add Replacement…", action: #selector(addReplacementEntry), keyEquivalent: "")
        addReplacement.target = self
        menu.addItem(addReplacement)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let notices = NSMenuItem(title: "About & Notices…", action: #selector(openNotices), keyEquivalent: "")
        notices.target = self
        menu.addItem(notices)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit KeyScribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen?() }

    func setStatus(_ text: String) { statusLine.title = "Status: \(text)" }
    func setHasResult(_ hasResult: Bool) { pasteLastItem.isEnabled = hasResult }

    // Tint the whole glyph red while capture is active (ui_design.md §Dynamic status — recording
    // reflects that capture is active); reverts on commit. The template image takes the tint.
    func setDictating(_ active: Bool) {
        statusItem.button?.contentTintColor = active ? .systemRed : nil
    }

    // The error badge — a small red dot, top-left (ui_design.md §6) — for a configuration, model, or
    // permission problem. A separate colored layer so it survives the recording tint and the template
    // glyph's appearance adaptation.
    func setErrorBadge(_ visible: Bool) { badgeDot.isHidden = !visible }
    func setModes(
        _ modes: [Mode], automaticName: String?, overrideName: String?,
        inertReasons: [String: String] = [:]
    ) {
        nextModeLine.title = overrideName.map { "Next dictation: \($0)" }
            ?? "Next dictation: Automatic\(automaticName.map { " — \($0)" } ?? "")"
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
        let manage = NSMenuItem(title: "Manage Modes…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        modesMenu.addItem(manage)
    }

    @objc private func pasteLast() { onPasteLast?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openNotices() { onOpenNotices?() }
    @objc private func selectAutomatic() { onSelectNextMode?(nil) }
    @objc private func selectMode(_ sender: NSMenuItem) { onSelectNextMode?(sender.representedObject as? String) }
    @objc private func addDictionaryEntry() { onAddDictionaryEntry?() }
    @objc private func addReplacementEntry() { onAddReplacement?() }
}
