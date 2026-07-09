import AppKit
import SwiftUI

struct ModelComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]
    var prompt: String?
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.delegate = context.coordinator
        combo.completes = false
        combo.usesDataSource = false
        combo.isEditable = true
        combo.focusRingType = .none
        combo.placeholderString = prompt
        combo.stringValue = text
        combo.addItems(withObjectValues: items)
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        let current = combo.objectValues.compactMap { $0 as? String }
        if current != items {
            combo.removeAllItems()
            combo.addItems(withObjectValues: items)
        }
        if combo.currentEditor() == nil, combo.stringValue != text {
            combo.stringValue = text
        }
        combo.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ModelComboBox

        init(_ parent: ModelComboBox) { self.parent = parent }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let combo = notification.object as? NSComboBox else { return }
                let index = combo.indexOfSelectedItem
                guard index >= 0, let value = combo.itemObjectValue(at: index) as? String else { return }
                commit(value)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let combo = notification.object as? NSComboBox else { return }
                commit(combo.stringValue)
            }
        }

        @MainActor private func commit(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
            parent.onCommit()
        }
    }
}
