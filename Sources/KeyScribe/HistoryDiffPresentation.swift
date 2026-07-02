import AppKit
import KeyScribeKit
import SwiftUI

enum ComparisonTextRole {
    case heard
    case local
    case result
}

struct ComparisonSection: Identifiable {
    struct Side {
        let title: String
        let role: ComparisonTextRole
        let text: String
    }

    let id: String
    let title: String
    let context: String
    let from: Side
    let to: Side
}

// One source of truth for diff styling so the text rendering and the legend never diverge. Meaning is
// never carried by color alone (ui_components.md §semantic colors): each changed kind also gets a
// background tint and a typographic mark, so removed/added/changed stay distinguishable in grayscale
// and for color-vision deficiency. Unchanged text recedes (secondary) so edits are what stand out.
enum DiffStyle {
    static func foreground(_ kind: TextComparison.Span.Kind) -> NSColor {
        switch kind {
        case .unchanged, .formatting: return .secondaryLabelColor
        case .removed: return .systemRed
        case .added: return .systemGreen
        case .changed: return .systemOrange
        }
    }

    static func background(_ kind: TextComparison.Span.Kind) -> NSColor? {
        switch kind {
        case .unchanged: return nil
        case .formatting: return NSColor.secondaryLabelColor.withAlphaComponent(0.14)
        case .removed: return NSColor.systemRed.withAlphaComponent(0.14)
        case .added: return NSColor.systemGreen.withAlphaComponent(0.14)
        case .changed: return NSColor.systemOrange.withAlphaComponent(0.16)
        }
    }

    enum Mark { case none, strikethrough, underline }
    static func mark(_ kind: TextComparison.Span.Kind) -> Mark {
        switch kind {
        case .unchanged, .formatting: return .none
        case .removed: return .strikethrough
        case .added, .changed: return .underline
        }
    }

    static func label(_ kind: TextComparison.Span.Kind) -> String {
        switch kind {
        case .unchanged: return "Unchanged"
        case .formatting: return "Formatting"
        case .removed: return "Removed"
        case .added: return "Added"
        case .changed: return "Changed"
        }
    }

    // Legend chips read as a key, so they use the solid foreground hue rather than the faint in-text tint.
    static func swatch(_ kind: TextComparison.Span.Kind) -> NSColor { foreground(kind) }

    static let legendOrder: [TextComparison.Span.Kind] = [.removed, .added, .changed, .formatting]
}

struct ComparisonSectionView: View {
    let section: ComparisonSection
    let onSelect: (ComparisonTextRole, String) -> Void

    var body: some View {
        // Compute the diff once per render — it is O(n·m) and was previously recomputed for each of
        // status, left, and right on every body evaluation (including the user's own text selection).
        let comparison = TextComparison.compare(section.from.text, section.to.text)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title).font(.headline)
                Spacer()
                Text(status(comparison.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(section.context)
                .font(.caption)
                .foregroundStyle(.secondary)
            ComparisonPane(
                title: section.from.title,
                role: section.from.role,
                spans: comparison.left,
                onSelect: onSelect)
            ComparisonPane(
                title: section.to.title,
                role: section.to.role,
                spans: comparison.right,
                onSelect: onSelect)
            DiffLegend(kinds: legendKinds(comparison))
        }
    }

    private func status(_ summary: TextComparison.Summary) -> String {
        switch summary {
        case .identical: return "No differences"
        case .formattingOnly: return "Only formatting changed"
        case .substitution(let from, let to): return "Changed \u{201C}\(from)\u{201D} \u{2192} \u{201C}\(to)\u{201D}"
        case .counts(let removed, let added, let changed):
            var parts: [String] = []
            if changed > 0 { parts.append("\(changed) changed") }
            if added > 0 { parts.append("\(added) added") }
            if removed > 0 { parts.append("\(removed) removed") }
            return parts.joined(separator: " \u{00B7} ")
        case .tooLongToCompare:
            return "Text changed \u{2014} too long to compare in detail"
        }
    }

    private func legendKinds(_ comparison: TextComparison) -> [TextComparison.Span.Kind] {
        let present = Set(comparison.left.map(\.kind)).union(comparison.right.map(\.kind))
        return DiffStyle.legendOrder.filter(present.contains)
    }
}

struct DiffLegend: View {
    let kinds: [TextComparison.Span.Kind]

    var body: some View {
        if !kinds.isEmpty {
            HStack(spacing: 12) {
                ForEach(kinds, id: \.self) { kind in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: DiffStyle.swatch(kind)))
                            .frame(width: 16, height: 11)
                        Text(DiffStyle.label(kind)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }
}

struct DiffTextPresentation {
    let attributed: NSAttributedString
    private let original: NSString
    private let displayRanges: [NSRange?]

    static func render(spans: [TextComparison.Span]) -> DiffTextPresentation {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

        guard !spans.isEmpty else {
            var placeholder = base
            placeholder[.foregroundColor] = NSColor.tertiaryLabelColor
            return DiffTextPresentation(
                attributed: NSAttributedString(string: "(empty)", attributes: placeholder),
                original: "",
                displayRanges: Array(repeating: nil, count: "(empty)".utf16.count))
        }

        let out = NSMutableAttributedString()
        var original = ""
        var displayRanges: [NSRange?] = []

        for span in spans {
            var attributes = base
            let color = DiffStyle.foreground(span.kind)
            attributes[.foregroundColor] = color
            if let background = DiffStyle.background(span.kind) {
                attributes[.backgroundColor] = background
            }
            switch DiffStyle.mark(span.kind) {
            case .none:
                break
            case .strikethrough:
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = color
            case .underline:
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = color
            }

            let reveal = span.kind != .unchanged
            for character in span.text {
                let originalRange = NSRange(location: original.utf16.count, length: String(character).utf16.count)
                original.append(character)
                let displayed = reveal ? visible(character) : String(character)
                out.append(NSAttributedString(string: displayed, attributes: attributes))
                for _ in 0..<displayed.utf16.count {
                    displayRanges.append(originalRange)
                }
            }
        }

        return DiffTextPresentation(attributed: out, original: original as NSString, displayRanges: displayRanges)
    }

    func originalText(for displayRange: NSRange) -> String {
        guard displayRange.length > 0 else { return "" }
        let start = max(0, displayRange.location)
        let end = min(displayRanges.count, displayRange.location + displayRange.length)
        guard start < end else { return "" }
        let ranges = displayRanges[start..<end].compactMap { $0 }
        guard var combined = ranges.first else { return "" }
        for range in ranges.dropFirst() {
            combined = NSUnionRange(combined, range)
        }
        return original.substring(with: combined)
    }

    private static func visible(_ character: Character) -> String {
        switch character {
        case "\n": return "\u{21B5}\n"
        case "\r": return "\u{240D}"
        case "\t": return "\u{21E5}"
        case " ": return "\u{00B7}"
        case "\u{00A0}": return "\u{237D}"
        default: return String(character)
        }
    }
}

struct ComparisonPane: View {
    let title: String
    let role: ComparisonTextRole
    let spans: [TextComparison.Span]
    let onSelect: (ComparisonTextRole, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if role == .heard {
                    Label("Select to correct", systemImage: "cursorarrow.click")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            SelectableComparisonText(spans: spans) { onSelect(role, $0) }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if role == .heard {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                    }
                }
        }
    }
}

struct SelectableComparisonText: NSViewRepresentable {
    let spans: [TextComparison.Span]
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Rebuild only when the spans actually change. Rebuilding on every render collapsed the user's
        // selection (the selection itself triggers a re-render), and restoring an old range into changed
        // text both selected the wrong characters and fired a stale onSelect. Keep the selection across a
        // pure attribute change (same text, different highlight); reset it on a real text change.
        guard context.coordinator.renderedSpans != spans else { return }
        let previousString = textView.string
        let rendered = DiffTextPresentation.render(spans: spans)
        let attributed = rendered.attributed
        let selected = textView.selectedRange()
        textView.textStorage?.setAttributedString(attributed)
        context.coordinator.renderedSpans = spans
        context.coordinator.presentation = rendered
        if previousString == attributed.string,
            selected.location + selected.length <= attributed.string.utf16.count {
            textView.setSelectedRange(selected)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String) -> Void
        var renderedSpans: [TextComparison.Span]?
        var presentation: DiffTextPresentation?
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onSelect(presentation?.originalText(for: textView.selectedRange()) ?? "")
        }
    }
}
