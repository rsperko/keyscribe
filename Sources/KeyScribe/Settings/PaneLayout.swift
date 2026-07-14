import SwiftUI

// Shared master/detail metrics for the list-driven Settings panes — Speech Models, AI Services, Modes,
// and History (ui_components.md "Settings list pane") — so the four read as one system.
enum PaneMetrics {
    static let listWidth: CGFloat = 260
}

// Data-boundary badges stay separate (DataBoundaryBadge) — those carry privacy meaning, this is neutral
// chrome for inline status words (the Speech "Recommended" pill, the Modes "Built in" capsule, etc).
struct PaneBadge: View {
    enum Kind { case neutral, prominent, warning }
    let text: String
    var kind: Kind
    var systemImage: String?

    init(_ text: String, kind: Kind = .neutral, systemImage: String? = nil) {
        self.text = text
        self.kind = kind
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(background, in: Capsule())
        .foregroundStyle(foreground)
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .neutral: AnyShapeStyle(.quaternary)
        case .prominent: AnyShapeStyle(.tint.opacity(0.2))
        case .warning: AnyShapeStyle(.orange.opacity(0.18))
        }
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .neutral: AnyShapeStyle(.primary)
        case .prominent: AnyShapeStyle(.tint)
        case .warning: AnyShapeStyle(.orange)
        }
    }
}

// Uses a small uppercase treatment distinct from the row title font, so it can never be mistaken for a
// list item. Shared by all four list panes so their section breaks read identically.
struct PaneListSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }
}

struct PaneRowStatus {
    let text: String
    let systemImage: String
    let style: AnyShapeStyle
}

// History keeps its own transcript row (a log entry, not a config item); the other three list panes
// share this one.
struct PaneListRow<Badges: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var status: PaneRowStatus? = nil
    @ViewBuilder var badges: () -> Badges
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    badges()
                }
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                if let status {
                    Label(status.text, systemImage: status.systemImage)
                        .font(.caption.weight(.medium)).foregroundStyle(status.style)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

extension PaneListRow where Badges == EmptyView {
    init(
        title: String, subtitle: String? = nil, status: PaneRowStatus? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(title: title, subtitle: subtitle, status: status, badges: { EmptyView() }, trailing: trailing)
    }
}

extension PaneListRow where Trailing == EmptyView {
    init(
        title: String, subtitle: String? = nil, status: PaneRowStatus? = nil,
        @ViewBuilder badges: @escaping () -> Badges
    ) {
        self.init(title: title, subtitle: subtitle, status: status, badges: badges, trailing: { EmptyView() })
    }
}

extension PaneListRow where Badges == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, status: PaneRowStatus? = nil) {
        self.init(title: title, subtitle: subtitle, status: status, badges: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct ListActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(.bar)
    }
}

extension View {
    func paneListActionBar<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { ListActionBar(content: content) }
    }
}

// Shared by Speech Models, AI Services, and History. Modes keeps its own editable summary card (its name
// is an editable field, not a title) but rhymes with this visually.
struct PaneDetailHeader<Badges: View, Trailing: View>: View {
    let systemImage: String
    var symbolStyle: AnyShapeStyle = AnyShapeStyle(.tint)
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var badges: () -> Badges
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(symbolStyle)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.title2.bold())
                    badges()
                }
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension PaneDetailHeader where Badges == EmptyView {
    init(
        systemImage: String, symbolStyle: AnyShapeStyle = AnyShapeStyle(.tint),
        title: String, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(systemImage: systemImage, symbolStyle: symbolStyle, title: title,
                  subtitle: subtitle, badges: { EmptyView() }, trailing: trailing)
    }
}

extension PaneDetailHeader where Trailing == EmptyView {
    init(
        systemImage: String, symbolStyle: AnyShapeStyle = AnyShapeStyle(.tint),
        title: String, subtitle: String? = nil,
        @ViewBuilder badges: @escaping () -> Badges
    ) {
        self.init(systemImage: systemImage, symbolStyle: symbolStyle, title: title,
                  subtitle: subtitle, badges: badges, trailing: { EmptyView() })
    }
}

extension PaneDetailHeader where Badges == EmptyView, Trailing == EmptyView {
    init(
        systemImage: String, symbolStyle: AnyShapeStyle = AnyShapeStyle(.tint),
        title: String, subtitle: String? = nil
    ) {
        self.init(systemImage: systemImage, symbolStyle: symbolStyle, title: title,
                  subtitle: subtitle, badges: { EmptyView() }, trailing: { EmptyView() })
    }
}

// Spatially separated at a detail pane's trailing edge in red — never stacked with routine maintenance
// (ui_design.md §7). Reused by every pane.
struct PaneDeleteButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: "trash").foregroundStyle(.red)
        }
    }
}
