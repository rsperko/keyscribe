import Foundation

extension ByteCountFormatter {
    // Reused instead of `ByteCountFormatter.string(fromByteCount:countStyle:)`, which builds a fresh
    // formatter on every call. @MainActor because it's only touched from SwiftUI views.
    @MainActor static let fileStyle: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
