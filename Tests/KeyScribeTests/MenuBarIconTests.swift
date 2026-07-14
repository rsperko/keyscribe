import AppKit
import KeyScribeKit
import Testing
@testable import KeyScribe

@MainActor
struct MenuBarIconTests {
    @Test func menuPutsEverydayDictationActionsBeforeManagement() {
        let controller = MenuBarController()
        controller.install()

        let titles = controller.mainMenu?.items.map(\.title) ?? []
        #expect(titles == [
            "starting…", "Next Dictation", "Paste Last Dictation", "",
            "Add to Vocabulary…", "", "Speech Model", "History…", "",
            "Settings…", "About & Notices…", "", "Quit \(Branding.appName)",
        ])
    }

    @Test func modeItemTitleShowsAModifierOnlyShortcut() {
        let title = MenuBarController.modeItemTitle(
            name: "Polish", trigger: try? KeyDescriptor(parsing: "right_option"), inertReason: nil)

        #expect(title == "Polish — Right-⌥")
    }

    @Test func modeItemTitleShowsAChordShortcut() {
        let title = MenuBarController.modeItemTitle(
            name: "Email", trigger: try? KeyDescriptor(parsing: "control+option+e"), inertReason: nil)

        #expect(title == "Email — ⌃⌥E")
    }

    // Guards the label source shared by the menu, the Settings mode list, and the hotkey recorder.
    @Test func modeItemShortcutMatchesTheSharedLabelSource() {
        for token in ["fn", "right_option", "right_command", "hyper", "control+option+e", "mouse2"] {
            guard let descriptor = try? KeyDescriptor(parsing: token) else {
                Issue.record("could not parse \(token)")
                continue
            }
            let title = MenuBarController.modeItemTitle(
                name: "Mode", trigger: descriptor, inertReason: nil)
            #expect(title == "Mode — \(descriptor.displayString)")
        }
    }

    @Test func modeItemTitleIsBareWhenNoShortcutIsAssigned() {
        let title = MenuBarController.modeItemTitle(name: "Direct", trigger: nil, inertReason: nil)

        #expect(title == "Direct")
    }

    @Test func modeItemTitleShowsAPhraseOnlyModesSpokenPhrase() {
        let title = MenuBarController.modeItemTitle(
            name: "Email", trigger: nil, phrase: "as an email", inertReason: nil)

        #expect(title == "Email — say \"as an email\"")
    }

    @Test func modeItemTitleJoinsAKeyAndAPhrase() {
        let title = MenuBarController.modeItemTitle(
            name: "Pig Latin", trigger: try? KeyDescriptor(parsing: "right_option"),
            phrase: "as pig latin", inertReason: nil)

        #expect(title == "Pig Latin — Right-⌥ · say \"as pig latin\"")
    }

    @Test func modeItemTitleKeepsShortcutAndInertReasonTogether() {
        let title = MenuBarController.modeItemTitle(
            name: "Email", trigger: try? KeyDescriptor(parsing: "fn"),
            inertReason: "needs an AI service")

        #expect(title == "Email — Fn (Globe) · needs an AI service")
    }

    @Test func modeItemDimsTheShortcutButNotTheName() {
        let attributed = MenuBarController.modeItemAttributedTitle(
            name: "Polish", trigger: try? KeyDescriptor(parsing: "right_option"), inertReason: nil)

        #expect(attributed.string == "Polish — Right-⌥")
        let nameColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let shortcutColor = attributed.attribute(
            .foregroundColor, at: attributed.length - 1, effectiveRange: nil) as? NSColor
        #expect(nameColor == nil)
        #expect(shortcutColor == NSColor.secondaryLabelColor)
    }

    @Test func modeItemAttributedTitleIsBareWhenNoShortcutIsAssigned() {
        let attributed = MenuBarController.modeItemAttributedTitle(
            name: "Direct", trigger: nil, inertReason: nil)

        #expect(attributed.string == "Direct")
        #expect(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test func dictateWithMenuRendersEachModesShortcut() {
        let controller = MenuBarController()
        controller.install()

        var polish = Mode(id: "polish", name: "Polish")
        polish.triggerKeys = [.init(key: "right_option")]
        var direct = Mode(id: "direct", name: "Direct")
        direct.triggerKeys = []

        controller.setModes([polish, direct], automaticName: "Direct", overrideName: nil)

        let titles = controller.modeMenuItems.map { $0.attributedTitle?.string ?? $0.title }
        #expect(titles.contains("Polish — Right-⌥"))
        #expect(titles.contains("Direct"))
    }

    @Test func statusIconIsTemplateSizedForTheMenuBar() {
        let image = MenuBarController.statusIcon

        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func updateAffordanceUsesAmberIndicator() {
        #expect(MenuBarController.updateTint.matches(.systemOrange))
        #expect(MenuBarController.updateIndicatorImage.isTemplate == false)
        #expect(MenuBarController.updateIndicatorImage.size == NSSize(width: 8, height: 8))
    }

    @Test func updateMenuItemCarriesIndicatorWhenAvailable() {
        let controller = MenuBarController()
        controller.install()

        controller.setUpdateAvailable(true)

        #expect(controller.updateItem.title == "Update Available…")
        #expect(controller.updateItem.image === MenuBarController.updateIndicatorImage)
    }

    @Test func checkForUpdatesItemAbsentWithoutAnUpdater() {
        let controller = MenuBarController()
        controller.install()

        let titles = controller.mainMenu?.items.map(\.title) ?? []
        #expect(!titles.contains("Check for Updates…"))
    }

    @Test func checkForUpdatesItemSitsBetweenSettingsAndAbout() {
        let controller = MenuBarController()
        controller.showsUpdateCheck = true
        controller.install()

        let titles = controller.mainMenu?.items.map(\.title) ?? []
        guard let settings = titles.firstIndex(of: "Settings…"),
              let check = titles.firstIndex(of: "Check for Updates…"),
              let about = titles.firstIndex(of: "About & Notices…")
        else {
            Issue.record("expected Settings…, Check for Updates…, and About & Notices… items")
            return
        }
        #expect(settings < check && check < about)
    }

    // Without `autoenablesItems = false`, AppKit force-enables this item at display time (its target
    // responds to its action), overriding `setHasResult(false)`; `NSMenu.update()` runs the same
    // validation pass AppKit runs before showing the menu, without needing it on screen.
    @Test func pasteLastDictationStaysDisabledWithNoResultUnderMenuValidation() {
        let controller = MenuBarController()
        controller.install()
        controller.setHasResult(false)

        controller.mainMenu?.update()

        #expect(controller.mainMenu?.autoenablesItems == false)
        #expect(controller.pasteLastMenuItem.isEnabled == false)
    }

    @Test func pasteLastDictationEnablesWhenAResultExists() {
        let controller = MenuBarController()
        controller.install()
        controller.setHasResult(true)

        controller.mainMenu?.update()

        #expect(controller.pasteLastMenuItem.isEnabled == true)
    }
}

private extension NSColor {
    func matches(_ other: NSColor) -> Bool {
        guard
            let left = usingColorSpace(.sRGB),
            let right = other.usingColorSpace(.sRGB)
        else { return false }

        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
            && abs(left.alphaComponent - right.alphaComponent) < 0.001
    }
}
