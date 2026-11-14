import Foundation

public struct ClaudeTranscriptTitle: Equatable, Sendable {
    public let explicitName: String?
    public let generatedTitle: String?
    public var displayTitle: String? { explicitName ?? generatedTitle }

    public init(explicitName: String? = nil, generatedTitle: String? = nil) {
        self.explicitName = explicitName
        self.generatedTitle = generatedTitle
    }
    private struct Entry: Decodable {
        var type: String
        var aiTitle: String?
        var customTitle: String?
    }

    private static let markers = [Data(#""type":"ai-title""#.utf8), Data(#""type":"custom-title""#.utf8)]

    public static func latest(in tail: Data, startsMidLine: Bool = false) -> String? {
        parse(in: tail, startsMidLine: startsMidLine).displayTitle
    }

    public static func parse(in tail: Data, startsMidLine: Bool = false) -> Self {
        var lines = tail.split(separator: UInt8(ascii: "\n"))
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        var generated: String?
        var explicit: String?
        var sawCustom = false
        for line in lines.reversed() {
            let data = Data(line)
            guard markers.contains(where: { data.range(of: $0) != nil }),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data)
            else { continue }
            if entry.type == "custom-title", !sawCustom {
                explicit = cleaned(entry.customTitle)
                sawCustom = true
            }
            if entry.type == "ai-title", generated == nil { generated = cleaned(entry.aiTitle) }
        }
        return Self(explicitName: explicit, generatedTitle: generated)
    }

    public static func projectFolder(for cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    private static func cleaned(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }
}
