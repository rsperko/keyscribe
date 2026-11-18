import AppKit
import KeyScribeKit
import SwiftUI

struct ModelComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]
    var prompt: String?
    var validation: ((String) -> UserInputValidation.Issue?)? = nil
    var onValidationIssue: ((UserInputValidation.Issue?) -> Void)? = nil
    var edits: PendingEdits? = nil
    var onTyping: ((String) -> Void)? = nil
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.delegate = context.coordinator
        combo.usesDataSource = false
        combo.completes = false
        combo.isEditable = true
        combo.numberOfVisibleItems = 12
        combo.focusRingType = .none
        combo.alignment = .natural
        combo.placeholderString = prompt
        combo.stringValue = text
        context.coordinator.allItems = items
        combo.addItems(withObjectValues: items)
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let coordinator = context.coordinator
        coordinator.shownText = text
        coordinator.entry.update { [weak coordinator, weak combo] in
            guard let coordinator, let combo else { return true }
            return coordinator.commit(combo.currentEditor()?.string ?? combo.stringValue)
        }
        edits?.register(coordinator.entry)
        return combo
    }

    static func dismantleNSView(_ combo: NSComboBox, coordinator: Coordinator) {
        coordinator.parent.edits?.remove(coordinator.entry)
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.allItems != items {
            context.coordinator.allItems = items
            combo.removeAllItems()
            combo.addItems(withObjectValues: items)
        }
        let previous = context.coordinator.shownText
        context.coordinator.shownText = text
        let unsaved = combo.currentEditor().map { $0.string != previous } ?? false
        if !unsaved, combo.stringValue != text {
            combo.stringValue = text
        }
        combo.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ModelComboBox
        var allItems: [String] = []
        let entry = PendingEdits.Entry()
        var shownText = ""
        private var popupOpen = false

        init(_ parent: ModelComboBox) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let combo = notification.object as? NSComboBox else { return }
                let editor = notification.userInfo?["NSFieldEditor"] as? NSText
                let query = editor?.string ?? combo.currentEditor()?.string ?? combo.stringValue
                showItems(ModelFilter.filter(allItems, query: query), in: combo)
                parent.onTyping?(query)
            }
        }

        func comboBoxWillPopUp(_ notification: Notification) {
            MainActor.assumeIsolated {
                popupOpen = true
                guard let combo = notification.object as? NSComboBox else { return }
                let query = combo.currentEditor()?.string ?? combo.stringValue
                let values = allItems.contains(query) ? allItems : ModelFilter.filter(allItems, query: query)
                showItems(values, in: combo)
            }
        }

        func comboBoxWillDismiss(_ notification: Notification) {
            MainActor.assumeIsolated { popupOpen = false }
        }

        // Fires on every keyboard browse through the open list, not just a confirmed pick. Deferring to the
        // next runloop turn distinguishes them: by then a real pick (click/Return) has dismissed the popup,
        // while an in-progress browse leaves it open — commit only the former. Enter/focus-loss are also
        // caught by controlTextDidEndEditing; the value guard dedups.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let combo = notification.object as? NSComboBox else { return }
                let index = combo.indexOfSelectedItem
                guard index >= 0, let value = combo.itemObjectValue(at: index) as? String else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.popupOpen else { return }
                        self.commit(value)
                    }
                }
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let combo = notification.object as? NSComboBox else { return }
                commit(combo.stringValue)
                parent.onTyping?(parent.text)
                showItems(allItems, in: combo)
            }
        }

        @MainActor private func showItems(_ values: [String], in combo: NSComboBox) {
            let current = combo.objectValues.compactMap { $0 as? String }
            guard current != values else { return }
            combo.removeAllItems()
            combo.addItems(withObjectValues: values)
        }

        @discardableResult
        @MainActor func commit(_ value: String) -> Bool {
            if let issue = parent.validation?(value) {
                parent.onValidationIssue?(issue)
                return false
            }
            parent.onValidationIssue?(nil)
            guard parent.text != value else { return true }
            parent.text = value
            parent.onCommit()
            return true
        }
    }
}
