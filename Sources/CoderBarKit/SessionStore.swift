import Foundation
import Combine

@MainActor
public final class SessionStore: ObservableObject {
    public struct Session: Identifiable, Equatable {
        public let id: String
        public let source: String
        public var sessionId: String?
        public var cwd: String?
        public var startedAt: Date
        public var endedAt: Date?
        public var eventCount: Int
        public var lastEvent: String?
        public var lastTool: String?
        public var lastUserMessage: String?
        public var lastAssistantMessage: String?
        public var planItems: [DesktopSessionDiscovery.PlanItem] = []
        public var rateLimitWindows: [DesktopSessionDiscovery.RateLimitWindow] = []
        public var childAgentDetails: [DesktopSessionDiscovery.ChildAgent] = []
        public var model: String?
        public var reasoningEffort: String?
        public var sessionTitle: String?
        public var firstPrompt: String?
        public var transcriptPath: String?
        public var conversationID: String?
        public var originator: String?
        public var threadSource: String?
        public var terminalBundleID: String?
        public var termProgram: String?
        public var termSessionID: String?
        public var tmuxPane: String?
        public var codexThreadID: String?
        public var parentPID: Int?
        public var costEstimate: Double
        public var statusText: String = "waiting"
        public var pendingApproval = false
        public var pendingInteraction: PendingInteraction?
        public var activeChildAgentIDs: Set<String> = []
        public var isAuxiliary = false
        public var dataOrigin = "hook"
        public var discoveredByDesktop = false
        public var lastHookActivityAt: Date?
        public var lastActivityAt: Date = Date()
        public var segments: [Segment] = []

        public struct Segment: Equatable {
            public var tool: String
            public var secs: Double
        }

        public var childAgents: Int { activeChildAgentIDs.count }

        public var hasOutstandingPlanItems: Bool {
            planItems.contains { $0.isOutstanding }
        }

        public var visualSource: String {
            dataOrigin == "claude-desktop" ? "claude_desktop" : source
        }

        public var displayTitle: String {
            let project = (cwd as NSString?)?.lastPathComponent
            let task = sessionTitle.flatMap(Self.cleanTitle)
                ?? firstPrompt.flatMap(Self.cleanPromptTitle)

            if let project, let task, task.caseInsensitiveCompare(project) != .orderedSame {
                return "\(project) · \(task)"
            }
            return task ?? project ?? "session \(sessionId?.prefix(8) ?? "?")"
        }

        private static func cleanTitle(_ value: String) -> String? {
            // Codex may persist the complete first request in `threads.title`.
            // Treat that value as a prompt instead of displaying its Markdown
            // envelope (attached-file list, headings, and ambient context).
            if value.range(of: "## My request:", options: .caseInsensitive) != nil
                || value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("# Files mentioned") {
                return cleanPromptTitle(value)
            }

            let title = value
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !title.isEmpty else { return nil }
            return title.count > 80 ? String(title.prefix(80)) + "…" : title
        }

        private static func cleanPromptTitle(_ value: String) -> String? {
            var prompt = value
            if let marker = prompt.range(of: "## My request:", options: .caseInsensitive) {
                prompt = String(prompt[marker.upperBound...])
            }
            let title = prompt
                .split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("# Files mentioned") }
            return title.flatMap(cleanTitle)
        }
    }

    public struct LogEvent: Identifiable, Equatable {
        public let id = UUID()
        public let at: Date
        public let source: String
        public let sessionKey: String?
        public let text: String
        public let isAlert: Bool
    }

    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var log: [LogEvent] = []
    public private(set) var logFileURL: URL

    public var visibleActiveSessions: [Session] {
        sessions.filter { $0.endedAt == nil && !$0.isAuxiliary }
    }

    private var handle: FileHandle?

    public init(dataDir: URL, replayOnStart: Bool = true) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        logFileURL = dataDir.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: logFileURL)
        handle?.seekToEndOfFile()
        if replayOnStart {
            replay()
        }
    }

    public func ingest(_ p: HookPayload) {
        let source = p.source ?? "unknown"
        let logicalSessionID = p.parentSessionID ?? p.resolvedSessionID
        let rawKey = "\(source)|\(logicalSessionID)"
        let desktopParentKey = claudeDesktopParentKey(for: p, rawKey: rawKey)
        let key = desktopParentKey ?? rawKey
        let routedClaudeChild = desktopParentKey != nil
        let at = Date()

        let text = Self.eventText(p, source: source)
        let isAlert = Self.isAlert(p)

        let index: Int?
        if let i = sessions.firstIndex(where: { $0.id == key }) {
            index = i
        } else {
            sessions.append(Session(
                id: key,
                source: source,
                sessionId: p.parentSessionID ?? p.sessionId,
                cwd: p.cwd,
                startedAt: at,
                eventCount: 0,
                lastEvent: nil,
                lastTool: nil,
                model: p.displayModel,
                reasoningEffort: p.reasoningEffort,
                sessionTitle: p.sessionTitle,
                firstPrompt: Self.isPromptEvent(p) ? p.prompt : nil,
                transcriptPath: p.transcriptPath,
                conversationID: p.conversationID,
                originator: p.originator,
                threadSource: p.threadSource,
                terminalBundleID: p.terminalBundleID,
                termProgram: p.termProgram,
                termSessionID: p.termSessionID,
                tmuxPane: p.tmuxPane,
                codexThreadID: p.codexThreadID,
                parentPID: p.parentPID,
                costEstimate: 0,
                isAuxiliary: Self.isAuxiliary(p)
            ))
            index = sessions.count - 1
        }

        if let i = index {
            var s = sessions[i]
            if let cwd = p.cwd, s.cwd == nil { s.cwd = cwd }
            if let m = p.displayModel { s.model = m }
            if let value = p.reasoningEffort { s.reasoningEffort = value }
            if let value = p.sessionTitle { s.sessionTitle = value }
            if Self.isPromptEvent(p), let value = p.prompt, s.firstPrompt == nil {
                s.firstPrompt = value
            }
            if let value = p.transcriptPath { s.transcriptPath = value }
            if let value = p.conversationID { s.conversationID = value }
            if let value = p.originator { s.originator = value }
            if let value = p.threadSource { s.threadSource = value }
            if let value = p.terminalBundleID { s.terminalBundleID = value }
            if let value = p.termProgram { s.termProgram = value }
            if let value = p.termSessionID { s.termSessionID = value }
            if let value = p.tmuxPane { s.tmuxPane = value }
            if let value = p.codexThreadID { s.codexThreadID = value }
            if let value = p.parentPID { s.parentPID = value }
            s.eventCount += 1
            s.lastHookActivityAt = at
            s.lastEvent = text
            if let tool = p.toolName { s.lastTool = tool }
            let cat = (p.category ?? p.hookEventName ?? "").lowercased()
            let isEnd = Self.isEnd(p)
            if !isEnd {
                s.endedAt = nil
            }

            // Keep human-in-the-loop states until the user responds. Desktop
            // snapshots must not erase these just because their files have not
            // recorded the answer yet.
            if let interaction = PendingInteraction.fromHook(p, at: at) {
                s.pendingInteraction = interaction
                s.statusText = Self.statusText(for: interaction.kind)
                s.pendingApproval = true
            } else if isEnd {
                s.statusText = "done"
                s.pendingApproval = false
                s.pendingInteraction = nil
            } else if Self.isFailureEvent(cat) {
                s.statusText = "error"
                s.pendingApproval = false
                s.pendingInteraction = nil
            } else if Self.isWaitingEvent(cat) {
                s.statusText = "waiting"
                if s.pendingInteraction == nil { s.pendingApproval = false }
            } else if p.toolName != nil
                        || cat.contains("pretooluse")
                        || cat == "posttooluse"
                        || cat == "beforetool"
                        || cat == "aftertool"
                        || cat == "beforeagent"
                        || cat == "userpromptsubmit" {
                s.statusText = "thinking"
                if s.pendingInteraction == nil { s.pendingApproval = false }
            }

            // tool segments with durations
            if let tool = p.toolName {
                let secs = max(0, at.timeIntervalSince(s.lastActivityAt))
                s.segments.append(.init(tool: tool, secs: secs))
                if s.segments.count > 40 { s.segments.removeFirst(s.segments.count - 40) }
            }
            s.lastActivityAt = at

            // child agents: SubagentStop / SubagentStart wire events
            let name = (p.hookMessageName ?? p.hookEventName ?? "").lowercased()
            let childID = p.agentID ?? p.agentName ?? p.sessionId ?? "unknown-child"
            if cat == "subagentstart" || name.contains("subagentstart") {
                s.activeChildAgentIDs.insert(childID)
            } else if cat == "subagentstop" || name.contains("subagentstop") {
                s.activeChildAgentIDs.remove(childID)
            }
            if routedClaudeChild {
                if cat == "sessionstart", let child = p.sessionId {
                    s.activeChildAgentIDs.insert(child)
                } else if isEnd, let child = p.sessionId {
                    s.activeChildAgentIDs.remove(child)
                }
            } else if !(s.discoveredByDesktop && s.sessionId == p.sessionId) {
                s.isAuxiliary = s.isAuxiliary || Self.isAuxiliary(p)
            }

            if isEnd { s.endedAt = at }
            if let price = Self.estimatedCost(p) {
                s.costEstimate += price
            }
            sessions[i] = s
        }

        log.insert(LogEvent(at: at, source: source, sessionKey: key, text: text, isAlert: isAlert), at: 0)
        if log.count > 500 { log.removeLast(log.count - 500) }

        persistFrame(p)
    }

    private func claudeDesktopParentKey(for p: HookPayload, rawKey: String) -> String? {
        guard p.source == "claude",
              p.terminalBundleID == "com.anthropic.claudefordesktop",
              !sessions.contains(where: { $0.id == rawKey && $0.discoveredByDesktop })
        else { return nil }

        return sessions
            .filter {
                $0.discoveredByDesktop
                    && $0.dataOrigin == "claude-desktop"
                    && $0.endedAt == nil
                    && $0.cwd == p.cwd
            }
            .max(by: { $0.lastActivityAt < $1.lastActivityAt })?
            .id
    }

    /// Reconciles the sessions that currently exist inside Codex App and
    /// Claude App. Desktop discovery owns membership and metadata; recent Hook
    /// events retain priority for transient states such as approvals.
    @discardableResult
    public func synchronizeDesktopSessions(
        _ snapshots: [DesktopSessionDiscovery.Snapshot]
    ) -> Bool {
        let now = Date()
        let liveIDs = Set(snapshots.map(\.id))
        var didChange = false

        for snapshot in snapshots {
            if let index = sessions.firstIndex(where: { $0.id == snapshot.id }) {
                var session = sessions[index]
                let previous = session
                session.sessionId = snapshot.sessionID
                session.cwd = snapshot.cwd
                session.model = snapshot.model
                session.reasoningEffort = snapshot.reasoningEffort
                session.sessionTitle = snapshot.title
                session.transcriptPath = snapshot.transcriptPath
                session.conversationID = snapshot.conversationID
                session.terminalBundleID = snapshot.terminalBundleID
                session.codexThreadID = snapshot.codexThreadID
                session.originator = snapshot.origin
                session.dataOrigin = snapshot.origin
                session.discoveredByDesktop = true
                session.startedAt = snapshot.startedAt
                session.endedAt = nil
                session.lastActivityAt = snapshot.lastActivityAt
                session.activeChildAgentIDs = snapshot.activeChildAgentIDs
                session.lastUserMessage = snapshot.lastUserMessage
                session.lastAssistantMessage = snapshot.lastAssistantMessage
                session.planItems = snapshot.planItems
                session.rateLimitWindows = snapshot.rateLimitWindows
                session.childAgentDetails = snapshot.childAgents
                session.isAuxiliary = false
                session.eventCount = max(1, session.eventCount)

                let hasRecentHookState = session.lastHookActivityAt.map {
                    now.timeIntervalSince($0) < 4
                } ?? false
                if session.pendingInteraction == nil, let interaction = snapshot.pendingInteraction {
                    session.pendingInteraction = interaction
                    session.pendingApproval = true
                    session.statusText = Self.statusText(for: interaction.kind)
                } else if session.pendingInteraction?.canRespond == false,
                          let interaction = snapshot.pendingInteraction {
                    session.pendingInteraction = interaction
                }
                if !hasRecentHookState && session.pendingInteraction == nil {
                    session.statusText = snapshot.statusText
                    session.pendingApproval = false
                    session.lastEvent = snapshot.lastEvent
                    session.lastTool = snapshot.lastTool
                }
                if session != previous {
                    sessions[index] = session
                    didChange = true
                }
            } else {
                sessions.append(Session(
                    id: snapshot.id,
                    source: snapshot.source,
                    sessionId: snapshot.sessionID,
                    cwd: snapshot.cwd,
                    startedAt: snapshot.startedAt,
                    endedAt: nil,
                    eventCount: 1,
                    lastEvent: snapshot.lastEvent,
                    lastTool: snapshot.lastTool,
                    lastUserMessage: snapshot.lastUserMessage,
                    lastAssistantMessage: snapshot.lastAssistantMessage,
                    planItems: snapshot.planItems,
                    rateLimitWindows: snapshot.rateLimitWindows,
                    childAgentDetails: snapshot.childAgents,
                    model: snapshot.model,
                    reasoningEffort: snapshot.reasoningEffort,
                    sessionTitle: snapshot.title,
                    firstPrompt: nil,
                    transcriptPath: snapshot.transcriptPath,
                    conversationID: snapshot.conversationID,
                    originator: snapshot.origin,
                    threadSource: "user",
                    terminalBundleID: snapshot.terminalBundleID,
                    termProgram: snapshot.source == "codex" ? "Codex" : "Claude",
                    termSessionID: nil,
                    tmuxPane: nil,
                    codexThreadID: snapshot.codexThreadID,
                    parentPID: nil,
                    costEstimate: 0,
                    statusText: snapshot.pendingInteraction.map { Self.statusText(for: $0.kind) }
                        ?? snapshot.statusText,
                    pendingApproval: snapshot.pendingInteraction != nil,
                    pendingInteraction: snapshot.pendingInteraction,
                    activeChildAgentIDs: snapshot.activeChildAgentIDs,
                    isAuxiliary: false,
                    dataOrigin: snapshot.origin,
                    discoveredByDesktop: true,
                    lastActivityAt: snapshot.lastActivityAt
                ))
                didChange = true
            }
        }

        for index in sessions.indices where sessions[index].discoveredByDesktop {
            guard !liveIDs.contains(sessions[index].id) else { continue }
            let hasRecentHookState = sessions[index].lastHookActivityAt.map {
                now.timeIntervalSince($0) < 4
            } ?? false
            guard !hasRecentHookState, sessions[index].pendingInteraction == nil else { continue }
            if sessions[index].endedAt == nil {
                sessions[index].endedAt = now
                sessions[index].statusText = "done"
                sessions[index].pendingApproval = false
                didChange = true
            }
        }
        return didChange
    }

    public func markInteractionResponded(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            NSLog("CoderBar could not clear interaction for unknown session %@", sessionID)
            return
        }
        sessions[index].pendingInteraction = nil
        sessions[index].pendingApproval = false
        sessions[index].statusText = "thinking"
        sessions[index].lastActivityAt = Date()
    }

    private func persistFrame(_ p: HookPayload) {
        let frame = WireFrame(
            source: p.source,
            category: p.category ?? p.hookEventName,
            payload: payloadDict(p),
            recordedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(frame) else { return }
        autoreleasepool {
            handle?.write(data)
            handle?.write(Data([0x0A]))
        }
    }

    private func payloadDict(_ p: HookPayload) -> [String: AnyValue] {
        var d: [String: AnyValue] = [:]
        if let v = p.hookEventName { d["hook_event_name"] = .string(v) }
        if let v = p.invocationId { d["invocation_id"] = .string(v) }
        if let v = p.toolUseId { d["tool_use_id"] = .string(v) }
        if let v = p.sessionId { d["session_id"] = .string(v) }
        if let v = p.transcriptPath { d["transcript_path"] = .string(v) }
        if let v = p.cwd { d["cwd"] = .string(v) }
        if let v = p.toolName { d["tool_name"] = .string(v) }
        if let v = p.toolInput { d["tool_input"] = .object(v) }
        if let v = p.question { d["question"] = .string(v) }
        if let v = p.prompt { d["prompt"] = .string(v) }
        if let v = p.permissionMode { d["permission_mode"] = .string(v) }
        if let v = p.permissionDecision { d["permission_decision"] = .string(v) }
        if let v = p.agentThought { d["agent_thought"] = .string(v) }
        if let v = p.model { d["model"] = .string(v) }
        if let v = p.effectiveModel { d["effective_model"] = .string(v) }
        if let v = p.reasoningEffort { d["reasoning_effort"] = .string(v) }
        if let v = p.sessionTitle { d["session_title"] = .string(v) }
        if let v = p.conversationID { d["conversation_id"] = .string(v) }
        if let v = p.parentSessionID { d["parent_session_id"] = .string(v) }
        if let v = p.agentID { d["agent_id"] = .string(v) }
        if let v = p.agentName { d["agent_name"] = .string(v) }
        if let v = p.originator { d["originator"] = .string(v) }
        if let v = p.threadSource { d["thread_source"] = .string(v) }
        if let v = p.answer { d["answer"] = .string(v) }
        if let v = p.elapsedMs { d["elapsed_ms"] = .number(Double(v)) }
        if let v = p.isBenchmark { d["is_benchmark"] = .bool(v) }
        if let v = p.hookMessageName { d["hook_message_name"] = .string(v) }
        if let v = p.terminalBundleID { d["terminal_bundle_id"] = .string(v) }
        if let v = p.termProgram { d["term_program"] = .string(v) }
        if let v = p.termSessionID { d["term_session_id"] = .string(v) }
        if let v = p.tmuxPane { d["tmux_pane"] = .string(v) }
        if let v = p.codexThreadID { d["codex_thread_id"] = .string(v) }
        if let v = p.parentPID { d["parent_pid"] = .number(Double(v)) }
        return d
    }

    private func replay() {
        let data: Data
        do {
            data = try Data(contentsOf: logFileURL)
        } catch {
            NSLog("CoderBar failed to replay session log: %@", String(describing: error))
            return
        }

        // Legacy frames did not record event time. Using the log file's single
        // modification date would incorrectly move every historical session to
        // today, so keep their time explicitly unknown/old instead.
        let legacyTimestamp = Date.distantPast
        var firstSeen: [String: Date] = [:]
        var malformedLineCount = 0

        for line in data.split(separator: 0x0A) {
            let frame: WireFrame
            do {
                frame = try JSONDecoder().decode(WireFrame.self, from: Data(line))
            } catch {
                malformedLineCount += 1
                continue
            }
            guard let raw = frame.payload else {
                malformedLineCount += 1
                continue
            }

            let p = HookPayload.wrap(source: frame.source, category: frame.category, payload: raw)
            let source = p.source ?? "unknown"
            let logicalSessionID = p.parentSessionID ?? p.resolvedSessionID
            let key = "\(source)|\(logicalSessionID)"
            let at = frame.recordedAt ?? legacyTimestamp
            if firstSeen[key] == nil { firstSeen[key] = at }
            let text = Self.eventText(p, source: source)
            let isEnd = Self.isEnd(p)

            if let i = sessions.firstIndex(where: { $0.id == key }) {
                var s = sessions[i]
                s.eventCount += 1
                s.lastEvent = text
                if let tool = p.toolName { s.lastTool = tool }
                if let cwd = p.cwd, s.cwd == nil { s.cwd = cwd }
                if let m = p.displayModel { s.model = m }
                if let value = p.reasoningEffort { s.reasoningEffort = value }
                if let value = p.sessionTitle { s.sessionTitle = value }
                if Self.isPromptEvent(p), let value = p.prompt, s.firstPrompt == nil {
                    s.firstPrompt = value
                }
                if let value = p.transcriptPath { s.transcriptPath = value }
                if let value = p.conversationID { s.conversationID = value }
                if let value = p.originator { s.originator = value }
                if let value = p.threadSource { s.threadSource = value }
                if let value = p.terminalBundleID { s.terminalBundleID = value }
                if let value = p.termProgram { s.termProgram = value }
                if let value = p.termSessionID { s.termSessionID = value }
                if let value = p.tmuxPane { s.tmuxPane = value }
                if let value = p.codexThreadID { s.codexThreadID = value }
                if let value = p.parentPID { s.parentPID = value }
                let category = (p.category ?? p.hookEventName ?? "").lowercased()
                let name = (p.hookMessageName ?? p.hookEventName ?? "").lowercased()
                let childID = p.agentID ?? p.agentName ?? p.sessionId ?? "unknown-child"
                if category == "subagentstart" || name.contains("subagentstart") {
                    s.activeChildAgentIDs.insert(childID)
                } else if category == "subagentstop" || name.contains("subagentstop") {
                    s.activeChildAgentIDs.remove(childID)
                }
                s.isAuxiliary = s.isAuxiliary || Self.isAuxiliary(p)
                s.lastActivityAt = at
                if isEnd { s.endedAt = at }
                if let price = Self.estimatedCost(p) { s.costEstimate += price }
                sessions[i] = s
            } else {
                sessions.append(Session(
                    id: key,
                    source: source,
                    sessionId: p.sessionId,
                    cwd: p.cwd,
                    startedAt: firstSeen[key] ?? at,
                    eventCount: 1,
                    lastEvent: text,
                    lastTool: p.toolName,
                    model: p.displayModel,
                    reasoningEffort: p.reasoningEffort,
                    sessionTitle: p.sessionTitle,
                    firstPrompt: Self.isPromptEvent(p) ? p.prompt : nil,
                    transcriptPath: p.transcriptPath,
                    conversationID: p.conversationID,
                    originator: p.originator,
                    threadSource: p.threadSource,
                    terminalBundleID: p.terminalBundleID,
                    termProgram: p.termProgram,
                    termSessionID: p.termSessionID,
                    tmuxPane: p.tmuxPane,
                    codexThreadID: p.codexThreadID,
                    parentPID: p.parentPID,
                    costEstimate: Self.estimatedCost(p) ?? 0,
                    isAuxiliary: Self.isAuxiliary(p),
                    lastActivityAt: at
                ))
            }

            log.append(LogEvent(
                at: at,
                source: source,
                sessionKey: key,
                text: text,
                isAlert: Self.isAlert(p)
            ))
        }

        // A persisted start event does not prove the agent is still alive after
        // this app restarts. Keep replayed entries as history until a new hook
        // event reactivates that exact session.
        for index in sessions.indices where sessions[index].endedAt == nil {
            sessions[index].endedAt = sessions[index].lastActivityAt
            sessions[index].statusText = "done"
            sessions[index].pendingApproval = false
        }
        log.reverse()

        if malformedLineCount > 0 {
            NSLog("CoderBar skipped %d malformed session log lines", malformedLineCount)
        }
    }

    // MARK: - Estimation

    private static func modelPrices(_ model: String?) -> (input: Double, output: Double) {
        let m = model?.lowercased() ?? ""
        if m.contains("opus") { return (15, 75) }
        if m.contains("sonnet") { return (3, 15) }
        if m.contains("haiku") { return (1, 5) }
        if m.contains("gemini") { return (1.25, 10) }
        if m.contains("codex") { return (2.5, 12) }
        if m.contains("gpt") { return (15, 75) }
        return (3, 15)
    }

    private static func charCount(_ value: AnyValue) -> Int {
        switch value {
        case .string(let s): return s.count
        case .object(let o): return o.reduce(0) { $0 + $1.key.count + charCount($1.value) }
        case .array(let a): return a.reduce(0) { $0 + charCount($1) }
        case .number(let n): return "\(n)".count
        case .bool(let b): return b ? 4 : 5
        case .null: return 4
        }
    }

    /// Rough USD cost for a tool call (input tokens only, tool content accounted once).
    private static func estimatedCost(_ p: HookPayload) -> Double? {
        guard let input = p.toolInput else { return nil }
        let chars = input.reduce(0) { $0 + Self.charCount($1.value) }
        guard chars > 0 else { return nil }
        let tokens = Double(chars) / 4.0
        let (pi, po) = modelPrices(p.displayModel)
        // output tokens guessed at 80% of input for a rough total
        return tokens * pi / 1_000_000 + tokens * 0.8 * po / 1_000_000
    }

    // MARK: - Text

    private static func isEnd(_ p: HookPayload) -> Bool {
        let c = (p.category ?? p.hookEventName ?? "").lowercased()
        return c.contains("sessionend")
            || c.contains("session_end")
            || c == "preexit"
            || c == "on_agent_stop"
    }

    private static func isPromptEvent(_ p: HookPayload) -> Bool {
        let category = (p.category ?? p.hookEventName ?? "").lowercased()
        return category == "userpromptsubmit" || category == "beforeagent"
    }

    private static func isAuxiliary(_ p: HookPayload) -> Bool {
        if p.source == "claude",
           p.terminalBundleID == "com.anthropic.claudefordesktop" {
            return true
        }
        guard p.source == "codex" else { return false }
        let metadata = [p.sessionTitle, p.originator, p.threadSource, p.agentName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return metadata.contains("memory writer")
            || metadata.contains("memory_writer")
            || metadata.contains("chronicle helper")
            || metadata.contains("subagent:memory")
    }

    private static func isWaitingEvent(_ category: String) -> Bool {
        category == "sessionstart"
            || category == "stop"
            || category == "afteragent"
    }

    private static func isFailureEvent(_ category: String) -> Bool {
        category == "stopfailure"
            || category == "posttoolusefailure"
            || category == "aftertoolfailure"
    }

    private static func statusText(for kind: PendingInteraction.Kind) -> String {
        switch kind {
        case .approval: return "approve"
        case .question: return "ask"
        case .planReview: return "plan_review"
        }
    }

    private static func isAlert(_ p: HookPayload) -> Bool {
        let c = (p.category ?? p.hookEventName ?? "").lowercased()
        return c.contains("permissionrequest")
            || c == "askuserquestion"
            || c.contains("notification")
            || PendingInteraction.fromHook(p) != nil
    }

    private static nonisolated func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    public static func eventText(_ p: HookPayload, source: String?) -> String {
        let agent = AgentNames.display(source)
        let c = p.category ?? p.hookEventName ?? p.hookMessageName ?? "event"
        var out = "\(agent) · \(c)"
        if let tool = p.toolName {
            out += " · \(tool)"
        }
        var detail: String?
        if let q = p.question, !q.isEmpty {
            detail = q
        } else if let prompt = p.prompt, !prompt.isEmpty {
            detail = prompt
        } else if let thought = p.agentThought, !thought.isEmpty {
            detail = thought
        } else if let decision = p.permissionDecision {
            detail = "decision: \(decision)"
        } else if let answer = p.answer, !answer.isEmpty {
            detail = answer
        } else if let input = p.toolInput {
            let parts = input.map { "\($0.key)=\(truncate(Self.charCount($0.value) > 160 ? Self.preview($0.value) : Self.preview($0.value), 160))" }
            if !parts.isEmpty { detail = parts.prefix(3).joined(separator: ", ") }
        }
        if let d = detail {
            out += " — \(truncate(d, 200))"
        }
        return out
    }

    private static func preview(_ value: AnyValue) -> String {
        switch value {
        case .string(let s): return s.replacingOccurrences(of: "\n", with: " ")
        case .object(let o): return o.keys.sorted().joined(separator: ",")
        case .array(let a): return "[\(a.count) items]"
        default: return value.stringValue ?? ""
        }
    }

    public static nonisolated func eventTextShort(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\n", with: " ")
        return truncate(clean, 200)
    }
}
