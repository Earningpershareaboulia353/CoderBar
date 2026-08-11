import Foundation

public struct PendingInteraction: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case approval
        case question
        case planReview
    }

    public struct Option: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let description: String?

        public init(id: String? = nil, label: String, description: String? = nil) {
            self.id = id ?? label
            self.label = label
            self.description = description
        }
    }

    public struct Question: Identifiable, Equatable, Sendable {
        public let id: String
        public let header: String?
        public let text: String
        public let isMultiSelect: Bool
        public let options: [Option]

        public init(
            id: String,
            header: String? = nil,
            text: String,
            isMultiSelect: Bool = false,
            options: [Option] = []
        ) {
            self.id = id
            self.header = header
            self.text = text
            self.isMultiSelect = isMultiSelect
            self.options = options
        }
    }

    public let id: String
    public let kind: Kind
    public let hookEventName: String
    public let toolName: String?
    public let title: String
    public let detail: String?
    public let questions: [Question]
    public let originalToolInput: [String: AnyValue]?
    public let canRespond: Bool
    public let createdAt: Date

    public init(
        id: String,
        kind: Kind,
        hookEventName: String,
        toolName: String?,
        title: String,
        detail: String?,
        questions: [Question] = [],
        originalToolInput: [String: AnyValue]? = nil,
        canRespond: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.questions = questions
        self.originalToolInput = originalToolInput
        self.canRespond = canRespond
        self.createdAt = createdAt
    }

    public static func fromHook(_ payload: HookPayload, at: Date = Date()) -> PendingInteraction? {
        let category = (payload.category ?? payload.hookEventName ?? "").lowercased()
        let tool = payload.toolName ?? ""
        let requestID = payload.invocationId ?? payload.toolUseId

        if category == "permissionrequest" {
            guard let requestID else { return nil }
            if tool.caseInsensitiveCompare("AskUserQuestion") == .orderedSame {
                return questionInteraction(
                    id: requestID,
                    event: "PermissionRequest",
                    payload: payload,
                    canRespond: false,
                    at: at
                )
            }
            return PendingInteraction(
                id: requestID,
                kind: .approval,
                hookEventName: "PermissionRequest",
                toolName: payload.toolName,
                title: "需要审批",
                detail: approvalDetail(payload),
                originalToolInput: payload.toolInput,
                canRespond: true,
                createdAt: at
            )
        }

        guard category == "pretooluse", let requestID else { return nil }
        if tool.caseInsensitiveCompare("AskUserQuestion") == .orderedSame {
            return questionInteraction(
                id: requestID,
                event: "PreToolUse",
                payload: payload,
                canRespond: true,
                at: at
            )
        }
        if tool.caseInsensitiveCompare("ExitPlanMode") == .orderedSame {
            return PendingInteraction(
                id: requestID,
                kind: .planReview,
                hookEventName: "PreToolUse",
                toolName: payload.toolName,
                title: "计划待确认",
                detail: payload.toolInput?["plan"]?.stringValue ?? "Agent 已完成计划，等待你的决定。",
                originalToolInput: payload.toolInput,
                canRespond: true,
                createdAt: at
            )
        }
        return nil
    }

    public static func codexQuestion(
        id: String,
        arguments: String,
        createdAt: Date = Date()
    ) -> PendingInteraction? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: AnyValue].self, from: data)
        else { return nil }
        let questions = parseQuestions(object["questions"])
        guard !questions.isEmpty else { return nil }
        return PendingInteraction(
            id: id,
            kind: .question,
            hookEventName: "CodexAppServer",
            toolName: "request_user_input",
            title: "Codex 正在提问",
            detail: nil,
            questions: questions,
            originalToolInput: object,
            canRespond: false,
            createdAt: createdAt
        )
    }

    public static func claudeTranscriptTool(
        id: String,
        name: String,
        input: [String: AnyValue],
        createdAt: Date = Date()
    ) -> PendingInteraction? {
        if name.caseInsensitiveCompare("AskUserQuestion") == .orderedSame {
            let questions = parseQuestions(input["questions"])
            guard !questions.isEmpty else { return nil }
            return PendingInteraction(
                id: id,
                kind: .question,
                hookEventName: "ClaudeTranscript",
                toolName: name,
                title: "Claude 正在提问",
                detail: nil,
                questions: questions,
                originalToolInput: input,
                canRespond: false,
                createdAt: createdAt
            )
        }
        if name.caseInsensitiveCompare("ExitPlanMode") == .orderedSame {
            return PendingInteraction(
                id: id,
                kind: .planReview,
                hookEventName: "ClaudeTranscript",
                toolName: name,
                title: "计划待确认",
                detail: input["plan"]?.stringValue ?? "Claude 已完成计划，等待你的决定。",
                originalToolInput: input,
                canRespond: false,
                createdAt: createdAt
            )
        }
        return nil
    }

    private static func questionInteraction(
        id: String,
        event: String,
        payload: HookPayload,
        canRespond: Bool,
        at: Date
    ) -> PendingInteraction {
        let questions = parseQuestions(payload.toolInput?["questions"])
        return PendingInteraction(
            id: id,
            kind: .question,
            hookEventName: event,
            toolName: payload.toolName,
            title: "Agent 正在提问",
            detail: questions.isEmpty ? payload.question ?? payload.prompt : nil,
            questions: questions,
            originalToolInput: payload.toolInput,
            canRespond: canRespond,
            createdAt: at
        )
    }

    private static func parseQuestions(_ value: AnyValue?) -> [Question] {
        guard case .array(let rawQuestions) = value else { return [] }
        return rawQuestions.enumerated().compactMap { index, raw in
            guard let object = raw.objectValue,
                  let text = object["question"]?.stringValue,
                  !text.isEmpty
            else { return nil }
            let id = object["id"]?.stringValue ?? text
            let rawOptions: [AnyValue]
            if case .array(let values) = object["options"] { rawOptions = values } else { rawOptions = [] }
            let options = rawOptions.compactMap { rawOption -> Option? in
                guard let option = rawOption.objectValue,
                      let label = option["label"]?.stringValue,
                      !label.isEmpty
                else { return nil }
                return Option(
                    id: option["id"]?.stringValue ?? label,
                    label: label,
                    description: option["description"]?.stringValue
                )
            }
            return Question(
                id: id.isEmpty ? "question-\(index)" : id,
                header: object["header"]?.stringValue,
                text: text,
                isMultiSelect: object["multiSelect"]?.boolValue
                    ?? object["multi_select"]?.boolValue
                    ?? false,
                options: options
            )
        }
    }

    private static func approvalDetail(_ payload: HookPayload) -> String? {
        if let command = payload.toolInput?["command"]?.stringValue { return command }
        if let path = payload.toolInput?["file_path"]?.stringValue { return path }
        if let prompt = payload.prompt, !prompt.isEmpty { return prompt }
        return payload.toolName.map { "允许执行 \($0)？" }
    }
}
