import Foundation

public struct HookPayload: Codable, Sendable {
    public var source: String?
    public var category: String?
    public var hookEventName: String?
    public var invocationId: String?
    public var toolUseId: String?
    public var sessionId: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var toolName: String?
    public var toolInput: [String: AnyValue]?
    public var question: String?
    public var prompt: String?
    public var permissionMode: String?
    public var permissionDecision: String?
    public var agentThought: String?
    public var model: String?
    public var elapsedMs: Int?
    public var answer: String?
    public var isBenchmark: Bool?
    public var hookMessageName: String?
    public var effectiveModel: String?
    public var reasoningEffort: String?
    public var sessionTitle: String?
    public var conversationID: String?
    public var parentSessionID: String?
    public var agentID: String?
    public var agentName: String?
    public var originator: String?
    public var threadSource: String?
    public var terminalBundleID: String?
    public var termProgram: String?
    public var termSessionID: String?
    public var tmuxPane: String?
    public var codexThreadID: String?
    public var parentPID: Int?

    public init() {}

    public enum CodingKeys: String, CodingKey {
        case source, category
        case hookEventName = "hook_event_name"
        case invocationId = "invocation_id"
        case toolUseId = "tool_use_id"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case question, prompt
        case permissionMode = "permission_mode"
        case permissionDecision = "permission_decision"
        case agentThought = "agent_thought"
        case model
        case elapsedMs = "elapsed_ms"
        case answer
        case isBenchmark = "is_benchmark"
        case hookMessageName = "hook_message_name"
        case effectiveModel = "effective_model"
        case reasoningEffort = "reasoning_effort"
        case sessionTitle = "session_title"
        case conversationID = "conversation_id"
        case parentSessionID = "parent_session_id"
        case agentID = "agent_id"
        case agentName = "agent_name"
        case originator
        case threadSource = "thread_source"
        case terminalBundleID = "terminal_bundle_id"
        case termProgram = "term_program"
        case termSessionID = "term_session_id"
        case tmuxPane = "tmux_pane"
        case codexThreadID = "codex_thread_id"
        case parentPID = "parent_pid"
    }

    /// Injectable context that is not part of the raw agent payload.
    public static func wrap(source: String?, category: String?, payload: [String: AnyValue]) -> HookPayload {
        var p = HookPayload()
        p.source = source
        p.category = category
        if let v = payload["hook_event_name"]?.stringValue { p.hookEventName = v }
        if let v = payload["invocation_id"]?.stringValue { p.invocationId = v }
        if let v = firstString(in: payload, keys: ["tool_use_id", "toolUseId", "call_id"]) {
            p.toolUseId = v
        }
        if let v = firstString(in: payload, keys: ["session_id", "sessionId"]) { p.sessionId = v }
        if let v = firstString(
            in: payload,
            keys: ["transcript_path", "agent_transcript_path", "codex_transcript_path"]
        ) { p.transcriptPath = v }
        if let v = payload["cwd"]?.stringValue { p.cwd = v }
        if let v = payload["tool_name"]?.stringValue { p.toolName = v }
        if let v = payload["tool_input"]?.objectValue { p.toolInput = v }
        if let v = payload["question"]?.stringValue { p.question = v }
        if let v = payload["prompt"]?.stringValue { p.prompt = v }
        if let v = payload["permission_mode"]?.stringValue { p.permissionMode = v }
        if let v = payload["permission_decision"]?.stringValue { p.permissionDecision = v }
        if let v = payload["agent_thought"]?.stringValue { p.agentThought = v }
        if let v = payload["model"]?.stringValue { p.model = v }
        if let v = payload["effective_model"]?.stringValue { p.effectiveModel = v }
        if let v = firstString(
            in: payload,
            keys: ["reasoning_effort", "model_reasoning_effort", "reasoningEffort"]
        ) { p.reasoningEffort = v }
        if let v = firstString(
            in: payload,
            keys: ["session_title", "custom_title", "task_title", "title"]
        ) { p.sessionTitle = v }
        if let v = firstString(
            in: payload,
            keys: ["conversation_id", "conversationId"]
        ) { p.conversationID = v }
        if let v = firstString(
            in: payload,
            keys: ["parent_session_id", "parentSessionId", "parent_thread_id"]
        ) { p.parentSessionID = v }
        if let v = firstString(in: payload, keys: ["agent_id", "agentId", "subagent_id"]) {
            p.agentID = v
        }
        if let v = firstString(in: payload, keys: ["agent_name", "agentName", "subagent_type"]) {
            p.agentName = v
        }
        if let v = payload["originator"]?.stringValue { p.originator = v }
        if let v = firstString(in: payload, keys: ["thread_source", "threadSource"]) {
            p.threadSource = v
        }
        if let v = payload["elapsed_ms"]?.numberValue { p.elapsedMs = Int(v) }
        if let v = payload["answer"]?.stringValue { p.answer = v }
        if let v = payload["is_benchmark"]?.boolValue {
            p.isBenchmark = v
        }
        if let v = payload["hook_message_name"]?.stringValue { p.hookMessageName = v }
        if let v = payload["terminal_bundle_id"]?.stringValue { p.terminalBundleID = v }
        if let v = payload["term_program"]?.stringValue { p.termProgram = v }
        if let v = payload["term_session_id"]?.stringValue { p.termSessionID = v }
        if let v = payload["tmux_pane"]?.stringValue { p.tmuxPane = v }
        if let v = firstString(
            in: payload,
            keys: ["codex_thread_id", "thread_id", "conversation_id"]
        ) {
            p.codexThreadID = v
        } else if source == "codex" {
            p.codexThreadID = p.sessionId
        }
        if let v = payload["parent_pid"]?.numberValue { p.parentPID = Int(v) }
        return p
    }

    private static func firstString(
        in payload: [String: AnyValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    public var displayModel: String? { effectiveModel ?? model }

    public var resolvedSessionID: String {
        if let sessionId { return sessionId }
        if let codexThreadID { return codexThreadID }
        if let transcriptPath { return transcriptPath }
        if let termSessionID { return termSessionID }
        if let tmuxPane { return tmuxPane }
        if let parentPID { return "process-\(parentPID)" }
        if let cwd { return "cwd-\(cwd)" }
        return "unknown"
    }
}

public struct WireFrame: Codable, Sendable {
    public var source: String?
    public var category: String?
    public var payload: [String: AnyValue]?
    public var recordedAt: Date?
}

public enum AgentNames {
    public static func display(_ source: String?) -> String {
        switch source {
        case "claude": return "Claude Code"
        case "claude_desktop": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "cursor": return "Cursor"
        case "devin": return "Devin"
        default: return source ?? "Unknown agent"
        }
    }
}
