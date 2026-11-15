import Foundation

public struct AgentPlace: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable { case title = "pane title", pane, agent = "agent name", tab, workspace }

    public struct Label: Equatable, Sendable {
        public var text: String
        public var level: Level
        public var container: String
        public var surface: String?
        public var term: String?
        public var onlyAfterVerb: Bool

        public init(text: String, level: Level, container: String, surface: String? = nil, term: String? = nil, onlyAfterVerb: Bool = false) {
            self.text = text
            self.level = level
            self.container = container
            self.surface = surface
            self.term = term
            self.onlyAfterVerb = onlyAfterVerb
        }

        public var word: String { term ?? level.rawValue }
    }

    public var surface: String
    public var labels: [Label]
    public var containers: [String]

    public init(surface: String, labels: [Label], containers: [String]) {
        self.surface = surface
        self.labels = labels
        self.containers = containers
    }
}
