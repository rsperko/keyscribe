import SwiftUI
import KeyScribeKit

// Renders a trigger as small physical-looking keycaps (phase 2). Pure token mapping lives in
// `KeyDescriptor.keycapTokens`; a descriptor with no tokens (a mouse button) falls back to plain text.
struct KeycapView: View {
    let descriptor: KeyDescriptor

    var body: some View {
        let tokens = descriptor.keycapTokens
        Group {
            if tokens.isEmpty {
                Text(descriptor.displayString)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        cap(token)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(descriptor.displayString)
    }

    @ViewBuilder private func cap(_ token: String) -> some View {
        HStack(spacing: 2) {
            if isFn(token) {
                Image(systemName: "globe").font(.caption)
            }
            Text(token)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                })
    }

    private func isFn(_ token: String) -> Bool {
        if case .named(.fn) = descriptor { return token == "fn" }
        return false
    }
}
