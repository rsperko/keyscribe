import Foundation

public enum BBThreads {
    public struct Thread: Equatable, Sendable {
        public var id: String
        public var folder: String
        public var state: AgentLiveState
        public var createdAt: Int?
        public var title: String?
        public var shownInstead: String?

        public init(
            id: String, folder: String, state: AgentLiveState, createdAt: Int? = nil, title: String? = nil, shownInstead: String? = nil
        ) {
            self.id = id
            self.folder = folder
            self.state = state
            self.createdAt = createdAt
            self.title = title
            self.shownInstead = shownInstead
        }
    }

    public enum Delivery: Equatable, Sendable {
        case sent
        case queued
        case refused(String, code: String?, message: String?)
        case unclear
    }

    private struct Listed: Decodable {
        var id: String
        var status: String?
        var visibility: String?
        var archivedAt: Double?
        var deletedAt: Double?
        var environmentPath: String?
        var hasPendingInteraction: Bool?
        var createdAt: Double?
        var title: String?
        var titleFallback: String?
    }

    private struct Told: Decodable {
        var ok: Bool?
        var delivery: String?
    }

    private struct Opened: Decodable {
        var delivered: Int?
    }

    private struct Failed: Decodable {
        struct Problem: Decodable {
            var code: String?
            var message: String?
        }
        var ok: Bool
        var error: Problem?
    }

    public static func parse(_ data: Data) -> [Thread]? {
        guard let listed = try? JSONDecoder().decode([Listed].self, from: data) else { return nil }
        return listed.compactMap { thread in
            guard isThreadId(thread.id), thread.archivedAt == nil, thread.deletedAt == nil, (thread.visibility ?? "visible") == "visible"
            else { return nil }
            let title = present(thread.title)
            return Thread(
                id: thread.id, folder: thread.environmentPath ?? "", state: state(thread), createdAt: thread.createdAt.flatMap { Int(exactly: $0) },
                title: title, shownInstead: title == nil ? present(thread.titleFallback) : nil)
        }
    }

    private static func present(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static func delivery(status: Int32, stdout: Data) -> Delivery {
        if status != 0 {
            guard let failed = try? JSONDecoder().decode(Failed.self, from: stdout), !failed.ok, let problem = failed.error,
                  problem.code != nil || problem.message != nil
            else { return .unclear }
            let reason = problem.code == "thread_not_found" ? "bb no longer has this thread." : "bb did not take it."
            return .refused(reason, code: problem.code, message: problem.message)
        }
        switch (try? JSONDecoder().decode(Told.self, from: stdout)).flatMap({ $0.ok == true ? $0.delivery : nil }) {
        case "sent": return .sent
        case "queued": return .queued
        default: return .unclear
        }
    }

    public static func openedWindows(status: Int32, stdout: Data) -> Int? {
        guard status == 0 else { return nil }
        return (try? JSONDecoder().decode(Opened.self, from: stdout))?.delivered
    }

    public static let threadKey = "BB_THREAD_ID"
    public static let storageKey = "BB_THREAD_STORAGE"

    public static func thread(in environment: [String: String], instance: String) -> String? {
        guard let id = environment[threadKey], isThreadId(id), let storage = environment[storageKey] else { return nil }
        let root = instance.hasSuffix("/") ? String(instance.dropLast()) : instance
        return storage == "\(root)/thread-storage/\(id)" ? id : nil
    }

    public static func isThreadId(_ id: String) -> Bool {
        id.hasPrefix("thr_") && id.count > 4 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func state(_ thread: Listed) -> AgentLiveState {
        if thread.hasPendingInteraction == true { return .waitingQuestion }
        switch thread.status {
        case "active", "starting": return .working
        default: return .idle
        }
    }
}
