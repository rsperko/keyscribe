import Foundation

public enum UltimateAddress {
    public static func reader(for kind: AgentKind) -> AgentNativeAddress {
        let head = AgentNativeRoster.words(kind.displayName)
        return AgentNativeAddress(agent: kind.id) { words in
            guard !head.isEmpty, words.starts(with: head) else { return nil }
            var rest = words.dropFirst(head.count)
            var used = head.count
            if let noun = rest.first, AgentAddress.rowNouns.contains(noun) {
                rest = rest.dropFirst()
                used += 1
            }
            guard let number = SpokenNumber.read(rest, forms: [.whole, .grouped]) else { return nil }
            return .init(native: number.value.map(String.init), words: used + number.words)
        }
    }
}
