import SwiftUI

struct DisclosureSection<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    label()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content() }
        }
    }
}

extension DisclosureSection where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._isExpanded = isExpanded
        self.label = { Text(title) }
        self.content = content
    }
}

// ui_components.md "Setting row with help": label + one-line result, the control, an inline
// Learn more disclosure carrying benefit/limit/prerequisite (and an optional example), plus a
// persistent dependency reason when the control is gated. No hover-only tooltips for anything
// that affects data, privacy, or output (ui_design.md §3).
struct SettingRow<Control: View>: View {
    let title: String
    var result: String? = nil
    let help: String
    var example: String? = nil
    var dependencyReason: String? = nil
    @ViewBuilder var control: () -> Control
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                control()
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "Hide details" : "Learn more")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if expanded {
                Text(help).font(.caption).foregroundStyle(.secondary)
                if let example {
                    Text(example)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let dependencyReason {
                Label(dependencyReason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, result].compactMap { $0 }.joined(separator: ", "))
    }
}

struct PromptEditor: View {
    let title: String
    @Binding var text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Button("Open in a larger editor…") { expanded = true }
                .font(.caption).buttonStyle(.link)
        }
        .sheet(isPresented: $expanded) {
            PromptEditorSheet(title: title, text: $text)
        }
    }
}

private struct PromptEditorSheet: View {
    let title: String
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 480, minHeight: 360)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
    }
}
