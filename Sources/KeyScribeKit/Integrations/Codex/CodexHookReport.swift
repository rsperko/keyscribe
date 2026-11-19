import Foundation

public enum CodexHookReport {
    public static let titleLimit = 300
    public static let detailLimit = 1000
    public static let notifyEvent = "KeyScribeNotify"
    public static let askTool = "request_user_input"

    private static let known: Set<String> = ["UserPromptSubmit", "Stop", "Interrupt", "PermissionRequest", "PreToolUse", notifyEvent, "SessionStart"]

    public static func events(_ body: Data, instance: String) -> [AgentEvent]? {
        guard let hook = CodexJSON.object(body), let name = hook["hook_event_name"] as? String else { return nil }
        guard known.contains(name) else { return [] }
        guard let native = CodexJSON.text(hook["session_id"]) else { return nil }
        let session = AgentHostLocation(host: CodexThread.agent, instance: instance, native: native).conversationKey
        let turn = CodexJSON.text(hook["turn_id"])
        switch name {
        case "UserPromptSubmit":
            guard let turn else { return nil }
            return [.turnStarted(session: session, turn: turn, prompt: (hook["prompt"] as? String).map(AgentPromptDigest.of))]
        case "Stop":
            return [.turnComplete(session: session, reason: "complete", answer: hook["last_assistant_message"] as? String ?? "")]
        case "Interrupt":
            return [.turnComplete(session: session, reason: "aborted", answer: "")]
        case "PermissionRequest":
            let input = hook["tool_input"] as? [String: Any]
            let prompt = AgentPrompt(
                kind: "confirm", tool: CodexJSON.clean(hook["tool_name"], limit: titleLimit), detail: CodexJSON.clean(input?["command"], limit: detailLimit))
            return [.waiting(session: session, prompt: prompt)]
        case "PreToolUse":
            guard hook["tool_name"] as? String == askTool else { return [] }
            return [.waiting(session: session, prompt: AgentPrompt(kind: "select", title: firstQuestion(hook["tool_input"])))]
        case notifyEvent:
            guard let turn else { return nil }
            return [.notify(session: session, turn: turn, on: true)]
        default:
            return []
        }
    }

    private static func firstQuestion(_ value: Any?) -> String? {
        guard let input = value as? [String: Any] else { return nil }
        if let first = (input["questions"] as? [Any])?.first {
            if let question = CodexJSON.clean(first, limit: titleLimit) { return question }
            if let question = CodexJSON.clean((first as? [String: Any])?["question"], limit: titleLimit) { return question }
        }
        return CodexJSON.clean(input["question"], limit: titleLimit)
    }
}
