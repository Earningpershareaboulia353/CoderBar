import Foundation

/// Reads the session indexes maintained by the desktop agent applications.
/// Hooks remain useful for low-latency events, but they are not the source of
/// truth for sessions that already exist inside Codex App or Claude App.
public enum DesktopSessionDiscovery {
    public struct PlanItem: Equatable, Sendable {
        public let title: String
        public let status: String

        public var isOutstanding: Bool {
            status != "completed"
        }

        public init(title: String, status: String) {
            self.title = title
            self.status = status
        }
    }

    public struct RateLimitWindow: Equatable, Sendable {
        public let usedPercent: Double
        public let windowMinutes: Int
        public let resetsAt: Date?

        public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    public struct ChildAgent: Equatable, Sendable, Identifiable {
        public let id: String
        public let nickname: String?
        public let role: String?
        public let task: String?
        public let model: String?
        public let reasoningEffort: String?
        public let statusText: String
        public let lastTool: String?
        public let startedAt: Date
        public let lastActivityAt: Date

        public init(
            id: String,
            nickname: String?,
            role: String?,
            task: String?,
            model: String?,
            reasoningEffort: String?,
            statusText: String,
            lastTool: String?,
            startedAt: Date,
            lastActivityAt: Date
        ) {
            self.id = id
            self.nickname = nickname
            self.role = role
            self.task = task
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.statusText = statusText
            self.lastTool = lastTool
            self.startedAt = startedAt
            self.lastActivityAt = lastActivityAt
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let id: String
        public let source: String
        public let sessionID: String
        public let title: String?
        public let cwd: String?
        public let model: String?
        public let reasoningEffort: String?
        public let transcriptPath: String?
        public let conversationID: String?
        public let codexThreadID: String?
        public let terminalBundleID: String
        public let origin: String
        public let startedAt: Date
        public let lastActivityAt: Date
        public let statusText: String
        public let lastEvent: String
        public let lastTool: String?
        public let activeChildAgentIDs: Set<String>
        public let lastUserMessage: String?
        public let lastAssistantMessage: String?
        public let planItems: [PlanItem]
        public let rateLimitWindows: [RateLimitWindow]
        public let childAgents: [ChildAgent]
        public let pendingInteraction: PendingInteraction?
    }

    public struct Report: Equatable, Sendable {
        public let sessions: [Snapshot]
        public let warnings: [String]
    }

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Report {
        var sessions: [Snapshot] = []
        var warnings: [String] = []

        do {
            let result = try discoverCodex(home: home)
            sessions.append(contentsOf: result.sessions)
            warnings.append(contentsOf: result.warnings)
        } catch {
            warnings.append("Codex App 会话发现失败：\(error.localizedDescription)")
        }

        do {
            let result = try discoverClaude(home: home)
            sessions.append(contentsOf: result.sessions)
            warnings.append(contentsOf: result.warnings)
        } catch {
            warnings.append("Claude App 会话发现失败：\(error.localizedDescription)")
        }

        return Report(sessions: sessions, warnings: warnings)
    }

    // MARK: - Codex App

    private struct CodexThreadRow: Decodable {
        let id: String
        let title: String?
        let cwd: String?
        let model: String?
        let reasoningEffort: String?
        let rolloutPath: String?
        let createdAtMS: Int64?
        let updatedAtMS: Int64?
        let threadSource: String?
        let childAgentsJSON: String?
        let preview: String?

        enum CodingKeys: String, CodingKey {
            case id, title, cwd, model
            case reasoningEffort = "reasoning_effort"
            case rolloutPath = "rollout_path"
            case createdAtMS = "created_at_ms"
            case updatedAtMS = "updated_at_ms"
            case threadSource = "thread_source"
            case childAgentsJSON = "child_agents"
            case preview
        }
    }

    private struct CodexChildRow: Decodable {
        let id: String
        let edgeStatus: String
        let nickname: String?
        let role: String?
        let model: String?
        let reasoningEffort: String?
        let title: String?
        let rolloutPath: String?
        let createdAtMS: Int64?
        let updatedAtMS: Int64?

        enum CodingKeys: String, CodingKey {
            case id, nickname, role, model, title
            case edgeStatus = "edge_status"
            case reasoningEffort = "reasoning_effort"
            case rolloutPath = "rollout_path"
            case createdAtMS = "created_at_ms"
            case updatedAtMS = "updated_at_ms"
        }
    }

    private struct DiscoveryPart {
        var sessions: [Snapshot]
        var warnings: [String]
    }

    private struct ActivityState {
        var statusText: String
        var lastTool: String?
        var lastUserMessage: String? = nil
        var lastAssistantMessage: String? = nil
        var planItems: [PlanItem] = []
        var rateLimitWindows: [RateLimitWindow] = []
        var pendingInteraction: PendingInteraction? = nil
    }

    private static let codexPlanCache = CodexPlanCache()

    private final class CodexPlanCache: @unchecked Sendable {
        private struct Entry {
            var offset: UInt64
            var plan: [PlanItem]
            var lastUserMessage: String?
            var lastAssistantMessage: String?
        }

        private var entries: [String: Entry] = [:]
        private let lock = NSLock()

        func content(
            at file: URL,
            parser: (String) -> [PlanItem]
        ) throws -> (plan: [PlanItem], lastUserMessage: String?, lastAssistantMessage: String?) {
            lock.lock()
            defer { lock.unlock() }

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            var entry = entries[file.path] ?? Entry(
                offset: 0,
                plan: [],
                lastUserMessage: nil,
                lastAssistantMessage: nil
            )
            if size < entry.offset {
                entry = Entry(
                    offset: 0,
                    plan: [],
                    lastUserMessage: nil,
                    lastAssistantMessage: nil
                )
            }
            guard size > entry.offset else {
                return (entry.plan, entry.lastUserMessage, entry.lastAssistantMessage)
            }

            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: entry.offset)
            let data = try handle.readToEnd() ?? Data()

            for bytes in [UInt8](data).split(separator: 0x0A) {
                let line = Data(bytes)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = object["type"] as? String,
                      let payload = object["payload"] as? [String: Any]
                else { continue }

                if type == "event_msg",
                   let event = payload["type"] as? String,
                   let message = payload["message"] as? String {
                    if event == "user_message" {
                        entry.lastUserMessage = DesktopSessionDiscovery.cleanMessage(message)
                    } else if event == "agent_message" {
                        entry.lastAssistantMessage = DesktopSessionDiscovery.cleanMessage(message)
                    }
                }

                if type == "response_item",
                   payload["type"] as? String == "custom_tool_call",
                   let input = payload["input"] as? String,
                   input.contains("update_plan") {
                    let nextPlan = parser(input)
                    if !nextPlan.isEmpty { entry.plan = nextPlan }
                }
            }

            entry.offset = size
            entries[file.path] = entry
            return (entry.plan, entry.lastUserMessage, entry.lastAssistantMessage)
        }
    }

    private static func discoverCodex(home: URL) throws -> DiscoveryPart {
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let databaseCandidates = [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("sqlite/state_5.sqlite"),
        ]
        guard let database = databaseCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return DiscoveryPart(sessions: [], warnings: [])
        }

        let lockDirectory = codexHome.appendingPathComponent("thread-writer-locks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: lockDirectory.path) else {
            return DiscoveryPart(sessions: [], warnings: [])
        }

        let lockFiles = try FileManager.default.contentsOfDirectory(
            at: lockDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "lock" }
        guard !lockFiles.isEmpty else {
            return DiscoveryPart(sessions: [], warnings: [])
        }

        let openThreadIDs = try openCodexThreadIDs(lockFiles: lockFiles)
        guard !openThreadIDs.isEmpty else {
            return DiscoveryPart(sessions: [], warnings: [])
        }

        let idList = openThreadIDs.sorted()
            .map { "'\(sqlQuoted($0))'" }
            .joined(separator: ",")
        let query = """
        SELECT
            t.id,
            t.title,
            t.cwd,
            t.model,
            t.reasoning_effort,
            t.rollout_path,
            t.created_at_ms,
            t.updated_at_ms,
            t.thread_source,
            t.preview,
            COALESCE((
                SELECT json_group_array(json_object(
                    'id', e.child_thread_id,
                    'edge_status', e.status,
                    'nickname', child.agent_nickname,
                    'role', child.agent_role,
                    'model', child.model,
                    'reasoning_effort', child.reasoning_effort,
                    'title', child.title,
                    'rollout_path', child.rollout_path,
                    'created_at_ms', child.created_at_ms,
                    'updated_at_ms', child.updated_at_ms
                ))
                FROM thread_spawn_edges e
                JOIN threads child ON child.id = e.child_thread_id
                WHERE e.parent_thread_id = t.id AND e.status = 'open'
            ), '[]') AS child_agents
        FROM threads t
        WHERE t.id IN (\(idList))
          AND t.archived = 0
          AND t.preview <> ''
          AND COALESCE(t.thread_source, 'user') = 'user'
        ORDER BY t.updated_at_ms DESC;
        """

        let databaseURI = "file:\(database.path)?mode=ro"
        let output = try runCommand(
            executable: "/usr/bin/sqlite3",
            arguments: ["-json", databaseURI, query]
        )
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = (normalizedOutput.isEmpty ? "[]" : normalizedOutput).data(using: .utf8) else {
            throw DiscoveryError.invalidUTF8("sqlite3")
        }
        let rows = try JSONDecoder().decode([CodexThreadRow].self, from: data)

        var warnings: [String] = []
        let idleCutoff = Date().addingTimeInterval(-30 * 60)
        let snapshots = rows.compactMap { row -> Snapshot? in
            var activity = ActivityState(statusText: "waiting", lastTool: nil)
            if let rolloutPath = row.rolloutPath, !rolloutPath.isEmpty {
                do {
                    activity = try codexActivity(at: URL(fileURLWithPath: rolloutPath))
                } catch {
                    warnings.append(
                        "Codex \(row.id.prefix(8)) 状态读取失败：\(error.localizedDescription)"
                    )
                }
            }

            let childRows: [CodexChildRow]
            if let rawChildren = row.childAgentsJSON?.data(using: .utf8) {
                do {
                    childRows = try JSONDecoder().decode([CodexChildRow].self, from: rawChildren)
                } catch {
                    warnings.append(
                        "Codex \(row.id.prefix(8)) 子 Agent 数据无法解析：\(error.localizedDescription)"
                    )
                    childRows = []
                }
            } else {
                childRows = []
            }

            let childAgents = childRows.map { child -> ChildAgent in
                var childActivity = ActivityState(
                    statusText: child.edgeStatus == "open" ? "thinking" : "waiting",
                    lastTool: nil
                )
                if let rolloutPath = child.rolloutPath, !rolloutPath.isEmpty {
                    do {
                        childActivity = try codexActivity(at: URL(fileURLWithPath: rolloutPath))
                    } catch {
                        warnings.append(
                            "Codex 子 Agent \(child.id.prefix(8)) 状态读取失败：\(error.localizedDescription)"
                        )
                    }
                }
                let childStartedAt = date(milliseconds: child.createdAtMS) ?? Date()
                let childLastActivityAt = date(milliseconds: child.updatedAtMS) ?? childStartedAt
                return ChildAgent(
                    id: child.id,
                    nickname: child.nickname,
                    role: child.role,
                    task: child.title.flatMap(cleanMessage),
                    model: child.model,
                    reasoningEffort: child.reasoningEffort,
                    statusText: childActivity.statusText,
                    lastTool: childActivity.lastTool,
                    startedAt: childStartedAt,
                    lastActivityAt: childLastActivityAt
                )
            }

            let startedAt = date(milliseconds: row.createdAtMS) ?? Date()
            let ownLastActivityAt = date(milliseconds: row.updatedAtMS) ?? startedAt
            let lastActivityAt = childAgents
                .map(\.lastActivityAt)
                .reduce(ownLastActivityAt, max)
            guard lastActivityAt >= idleCutoff else { return nil }
            let childIDs = Set(childAgents.map(\.id))
            return Snapshot(
                id: "codex|\(row.id)",
                source: "codex",
                sessionID: row.id,
                title: row.title,
                cwd: row.cwd,
                model: row.model,
                reasoningEffort: row.reasoningEffort,
                transcriptPath: row.rolloutPath,
                conversationID: nil,
                codexThreadID: row.id,
                terminalBundleID: "com.openai.codex",
                origin: "codex-desktop",
                startedAt: startedAt,
                lastActivityAt: lastActivityAt,
                statusText: activity.statusText,
                lastEvent: activity.statusText == "thinking"
                    ? "Codex App · 正在处理"
                    : "Codex App · 等待输入",
                lastTool: activity.lastTool,
                activeChildAgentIDs: childIDs,
                lastUserMessage: activity.lastUserMessage ?? cleanPrompt(row.preview),
                lastAssistantMessage: activity.lastAssistantMessage,
                planItems: activity.planItems,
                rateLimitWindows: activity.rateLimitWindows,
                childAgents: childAgents,
                pendingInteraction: activity.pendingInteraction
            )
        }

        return DiscoveryPart(sessions: snapshots, warnings: warnings)
    }

    private static func openCodexThreadIDs(lockFiles: [URL]) throws -> Set<String> {
        let arguments = ["-Fn"] + lockFiles.map(\.path)
        do {
            let output = try runCommand(executable: "/usr/sbin/lsof", arguments: arguments)
            return Set(output.split(whereSeparator: \.isNewline).compactMap { line in
                guard line.first == "n" else { return nil }
                let file = URL(fileURLWithPath: String(line.dropFirst()))
                guard file.pathExtension == "lock" else { return nil }
                return file.deletingPathExtension().lastPathComponent
            })
        } catch let error as CommandError where error.exitCode == 1 {
            // lsof uses exit code 1 when none of the candidate lock files is open.
            return []
        }
    }

    private static func codexActivity(at rollout: URL) throws -> ActivityState {
        let lines = try tailLines(at: rollout, maximumBytes: 512 * 1024)
        var lastTool: String?
        var sawInProgressActivity = false
        var resolvedStatus: String?
        let cachedContent = try codexPlanCache.content(at: rollout, parser: parseCodexPlan)
        var lastUserMessage = cachedContent.lastUserMessage
        var lastAssistantMessage = cachedContent.lastAssistantMessage
        let planItems = cachedContent.plan
        var rateLimitWindows: [RateLimitWindow] = []
        var pendingInteraction: PendingInteraction?
        var completedCallIDs = Set<String>()

        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            if type == "response_item",
               payload["type"] as? String == "custom_tool_call" {
                if lastTool == nil {
                    lastTool = payload["name"] as? String
                }
            }
            if type == "response_item",
               payload["type"] as? String == "function_call_output",
               let callID = payload["call_id"] as? String {
                completedCallIDs.insert(callID)
            }
            if pendingInteraction == nil,
               type == "response_item",
               payload["type"] as? String == "function_call",
               payload["name"] as? String == "request_user_input",
               let callID = payload["call_id"] as? String,
               !completedCallIDs.contains(callID),
               let arguments = payload["arguments"] as? String {
                pendingInteraction = PendingInteraction.codexQuestion(
                    id: callID,
                    arguments: arguments
                )
            }
            if type == "response_item" {
                sawInProgressActivity = true
            }

            guard type == "event_msg", let event = payload["type"] as? String else {
                continue
            }
            if rateLimitWindows.isEmpty,
               event == "token_count",
               let rawLimits = payload["rate_limits"] as? [String: Any] {
                rateLimitWindows = parseRateLimitWindows(rawLimits)
            }
            if lastAssistantMessage == nil,
               event == "agent_message",
               let message = payload["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastAssistantMessage = cleanMessage(message)
            }
            if lastUserMessage == nil,
               event == "user_message",
               let message = payload["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastUserMessage = cleanMessage(message)
            }
            if resolvedStatus == nil, event == "task_complete" {
                resolvedStatus = "waiting"
            } else if resolvedStatus == nil,
                      event == "task_started" || event == "user_message" {
                resolvedStatus = "thinking"
            }
        }

        return ActivityState(
            statusText: resolvedStatus ?? (sawInProgressActivity ? "thinking" : "waiting"),
            lastTool: lastTool,
            lastUserMessage: lastUserMessage,
            lastAssistantMessage: lastAssistantMessage,
            planItems: planItems,
            rateLimitWindows: rateLimitWindows,
            pendingInteraction: pendingInteraction
        )
    }

    // MARK: - Claude App

    private struct ClaudeSessionRecord: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let title: String?
        let cwd: String?
        let model: String?
        let effort: String?
        let createdAt: Int64?
        let lastActivityAt: Int64?
        let isArchived: Bool?
        let completedTurns: Int?
    }

    private static func discoverClaude(home: URL) throws -> DiscoveryPart {
        let support = home.appendingPathComponent("Library/Application Support/Claude")
        let roots = [
            support.appendingPathComponent("claude-code-sessions", isDirectory: true),
            support.appendingPathComponent("local-agent-mode-sessions", isDirectory: true),
        ]
        var recordsByCLI: [String: ClaudeSessionRecord] = [:]
        var warnings: [String] = []
        // Claude App keeps waiting sessions alive longer than Codex and does
        // not expose their worker process after a turn completes. A short
        // process-only or 30-minute filter drops real sessions that remain
        // visible and clickable in Claude App.
        let idleCutoffMS = Int64(Date().addingTimeInterval(-2 * 60 * 60).timeIntervalSince1970 * 1_000)

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                warnings.append("无法枚举 Claude App 会话目录：\(root.path)")
                continue
            }

            for case let file as URL in enumerator {
                guard file.pathExtension == "json", file.lastPathComponent.hasPrefix("local_") else {
                    continue
                }
                do {
                    let record = try JSONDecoder().decode(
                        ClaudeSessionRecord.self,
                        from: Data(contentsOf: file)
                    )
                    guard let cliID = record.cliSessionId,
                          record.isArchived != true,
                          (record.lastActivityAt ?? 0) >= idleCutoffMS
                    else { continue }

                    if let current = recordsByCLI[cliID],
                       !shouldPreferClaudeRecord(record, over: current) {
                        continue
                    }
                    recordsByCLI[cliID] = record
                } catch {
                    warnings.append(
                        "Claude 会话文件 \(file.lastPathComponent) 无法解析：\(error.localizedDescription)"
                    )
                }
            }
        }

        let transcriptIndex = try claudeTranscriptIndex(
            home: home,
            sessionIDs: Set(recordsByCLI.keys)
        )
        var snapshots: [Snapshot] = []
        for (cliID, record) in recordsByCLI {
            let importedFromID = record.sessionId.hasPrefix("local_")
                ? String(record.sessionId.dropFirst("local_".count))
                : nil
            let importedFrom = importedFromID.flatMap { recordsByCLI[$0] }
            var activity = ActivityState(statusText: "waiting", lastTool: nil)
            let transcript = transcriptIndex[cliID]
                ?? importedFromID.flatMap { transcriptIndex[$0] }
            if let transcript {
                do {
                    activity = try claudeActivity(at: transcript)
                } catch {
                    warnings.append(
                        "Claude \(cliID.prefix(8)) 状态读取失败：\(error.localizedDescription)"
                    )
                }
            }

            let startedAt = date(milliseconds: record.createdAt) ?? Date()
            let lastActivityAt = date(milliseconds: record.lastActivityAt) ?? startedAt
            snapshots.append(Snapshot(
                id: "claude|\(cliID)",
                source: "claude",
                sessionID: cliID,
                title: record.title ?? importedFrom?.title,
                cwd: record.cwd ?? importedFrom?.cwd,
                model: record.model ?? importedFrom?.model,
                reasoningEffort: record.effort ?? importedFrom?.effort,
                transcriptPath: transcript?.path,
                conversationID: record.sessionId,
                codexThreadID: nil,
                terminalBundleID: "com.anthropic.claudefordesktop",
                origin: "claude-desktop",
                startedAt: startedAt,
                lastActivityAt: lastActivityAt,
                statusText: activity.statusText,
                lastEvent: activity.statusText == "thinking"
                    ? "Claude App · 正在处理"
                    : "Claude App · 等待输入",
                lastTool: activity.lastTool,
                activeChildAgentIDs: [],
                lastUserMessage: activity.lastUserMessage,
                lastAssistantMessage: activity.lastAssistantMessage,
                planItems: [],
                rateLimitWindows: [],
                childAgents: [],
                pendingInteraction: activity.pendingInteraction
            ))
        }

        return DiscoveryPart(
            sessions: snapshots.sorted { $0.lastActivityAt > $1.lastActivityAt },
            warnings: warnings
        )
    }

    /// Claude can create a zero-turn import placeholder for a CLI bridge ID.
    /// Prefer the record with real conversation metadata over a newer empty
    /// placeholder, then use activity time only as the tie breaker.
    private static func shouldPreferClaudeRecord(
        _ candidate: ClaudeSessionRecord,
        over current: ClaudeSessionRecord
    ) -> Bool {
        func score(_ record: ClaudeSessionRecord) -> Int {
            var value = min(record.completedTurns ?? 0, 100) * 20
            if (record.completedTurns ?? 0) > 0 { value += 1_000 }
            if record.title?.isEmpty == false { value += 200 }
            if record.model?.isEmpty == false { value += 100 }
            if record.effort?.isEmpty == false { value += 50 }
            return value
        }

        let candidateScore = score(candidate)
        let currentScore = score(current)
        if candidateScore != currentScore { return candidateScore > currentScore }
        return (candidate.lastActivityAt ?? 0) > (current.lastActivityAt ?? 0)
    }

    private static func claudeTranscriptIndex(
        home: URL,
        sessionIDs: Set<String>
    ) throws -> [String: URL] {
        guard !sessionIDs.isEmpty else { return [:] }
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else { return [:] }
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DiscoveryError.cannotEnumerate(projects.path)
        }

        var result: [String: URL] = [:]
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            if sessionIDs.contains(id) { result[id] = file }
        }
        return result
    }

    private static func claudeActivity(at transcript: URL) throws -> ActivityState {
        let lines = try tailLines(at: transcript, maximumBytes: 384 * 1024)
        var lastTool: String?
        var lastUserMessage: String?
        var lastAssistantMessage: String?
        var statusText: String?
        var pendingTools: [String: PendingInteraction] = [:]
        var pendingOrder: [String] = []

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            if type == "assistant", let message = object["message"] as? [String: Any] {
                if let content = message["content"] as? [[String: Any]] {
                    if let tool = content.last(where: { $0["type"] as? String == "tool_use" }) {
                        lastTool = tool["name"] as? String ?? lastTool
                    }
                    for block in content where block["type"] as? String == "tool_use" {
                        guard let id = block["id"] as? String,
                              let name = block["name"] as? String,
                              let input = anyValueObject(block["input"]),
                              let interaction = PendingInteraction.claudeTranscriptTool(
                                id: id,
                                name: name,
                                input: input
                              )
                        else { continue }
                        pendingTools[id] = interaction
                        pendingOrder.removeAll { $0 == id }
                        pendingOrder.append(id)
                    }
                    if let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                        lastAssistantMessage = cleanMessage(text)
                    }
                }
                let stopReason = message["stop_reason"] as? String
                if stopReason == "end_turn" {
                    statusText = "waiting"
                }
                if stopReason == "tool_use" {
                    statusText = "thinking"
                }
            }
            if type == "user", let message = object["message"] as? [String: Any] {
                let directText = message["content"] as? String
                let blocks = message["content"] as? [[String: Any]]
                let blockText = blocks?
                    .last(where: { $0["type"] as? String == "text" })?["text"] as? String
                for block in blocks ?? [] where block["type"] as? String == "tool_result" {
                    if let toolUseID = block["tool_use_id"] as? String {
                        pendingTools.removeValue(forKey: toolUseID)
                    }
                }
                if let text = directText ?? blockText {
                    lastUserMessage = cleanMessage(text)
                    statusText = "thinking"
                }
            }
        }

        return ActivityState(
            statusText: statusText ?? "waiting",
            lastTool: lastTool,
            lastUserMessage: lastUserMessage,
            lastAssistantMessage: lastAssistantMessage,
            pendingInteraction: pendingOrder.reversed().compactMap { pendingTools[$0] }.first
        )
    }

    private static func anyValueObject(_ value: Any?) -> [String: AnyValue]? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? JSONDecoder().decode([String: AnyValue].self, from: data)
    }

    private static func parseCodexPlan(_ input: String) -> [PlanItem] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\s*\"?step\"?\s*:\s*\"((?:\\.|[^\"])*)\"\s*,\s*\"?status\"?\s*:\s*\"([^\"]+)\"\s*\}"#
        ) else { return [] }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: input),
                  let statusRange = Range(match.range(at: 2), in: input)
            else { return nil }
            let escapedTitle = String(input[titleRange])
            let title = escapedTitle
                .replacingOccurrences(of: #"\""#, with: #"""#)
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
            return PlanItem(title: title, status: String(input[statusRange]))
        }
    }

    private static func parseRateLimitWindows(_ limits: [String: Any]) -> [RateLimitWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let usedPercent = (window["used_percent"] as? NSNumber)?.doubleValue,
                  let windowMinutes = (window["window_minutes"] as? NSNumber)?.intValue,
                  windowMinutes > 0
            else { return nil }
            let resetsAt = (window["resets_at"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            return RateLimitWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt
            )
        }
        .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    private static func cleanPrompt(_ value: String?) -> String? {
        guard var value else { return nil }
        if let marker = value.range(of: "## My request:", options: .caseInsensitive) {
            value = String(value[marker.upperBound...])
        }
        return cleanMessage(value)
    }

    private static func cleanMessage(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized.count > 360 ? String(normalized.prefix(360)) + "…" : normalized
    }

    // MARK: - IO

    private struct CommandError: LocalizedError {
        let executable: String
        let exitCode: Int32
        let stderr: String

        var errorDescription: String? {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(executable) 退出码 \(exitCode)"
                : "\(executable) 退出码 \(exitCode)：\(detail)"
        }
    }

    private enum DiscoveryError: LocalizedError {
        case invalidUTF8(String)
        case cannotEnumerate(String)

        var errorDescription: String? {
            switch self {
            case .invalidUTF8(let source): return "\(source) 返回了无效文本"
            case .cannotEnumerate(let path): return "无法枚举目录：\(path)"
            }
        }
    }

    private static func runCommand(executable: String, arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError(executable: executable, exitCode: 127, stderr: "可执行文件不存在")
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorText = String(data: errorData, encoding: .utf8) ?? "stderr 不是 UTF-8"
        guard process.terminationStatus == 0 else {
            throw CommandError(
                executable: executable,
                exitCode: process.terminationStatus,
                stderr: errorText
            )
        }
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw DiscoveryError.invalidUTF8(executable)
        }
        return output
    }

    private static func tailLines(at file: URL, maximumBytes: UInt64) throws -> [Data] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let offset = size > maximumBytes ? size - maximumBytes : 0
        let handle = try FileHandle(forReadingFrom: file)
        defer {
            do {
                try handle.close()
            } catch {
                NSLog("CoderBar could not close session file %@: %@", file.path, String(describing: error))
            }
        }
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()

        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        return [UInt8](data).split(separator: 0x0A).map { bytes in
            Data(bytes)
        }
    }

    private static func date(milliseconds: Int64?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func sqlQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
