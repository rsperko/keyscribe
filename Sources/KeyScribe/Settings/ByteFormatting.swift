import Foundation

extension ByteCountFormatter {
    // Shared file-style formatter. `ByteCountFormatter.string(fromByteCount:countStyle:)` builds a
    // fresh formatter on every call; this is reused from the model-list render paths instead. Main-actor
    // isolated because it is only touched from SwiftUI views.
    @MainActor static let fileStyle: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
