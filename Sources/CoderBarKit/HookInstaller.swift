import Foundation

/// Merges `coder-bar-hook` invocations into agent hook configs
/// (~/.claude/settings.json, ~/.codex/hooks.json, ~/.gemini/settings.json).
/// Never overwrites user entries — always merges and backs up first.
public struct HookInstaller {
    public let home: URL
    public let hookBin: URL
    public let port: UInt16

    public struct Result: CustomStringConvertible {
        public var backups: [String] = []
        public var installed: [String] = []
        public var removed: [String] = []
        public var skipped: [String] = []

        public var description: String {
            var lines: [String] = []
            if !backups.isEmpty { lines.append("Backups: \(backups.joined(separator: ", "))") }
            for f in installed { lines.append("installed: \(f)") }
            for f in removed { lines.append("removed: \(f)") }
            for f in skipped { lines.append("skipped: \(f)") }
            return lines.isEmpty ? "no changes" : lines.joined(separator: "\n")
        }
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                hookBin: URL,
                port: UInt16) {
        self.home = home
        self.hookBin = hookBin
        self.port = port
    }

    private func command(_ source: String, _ category: String) -> String {
        "\(stableHookBin.path) --source \(source) --category \(category)"
    }

    private var stableHookBin: URL {
        home.appendingPathComponent(".coderbar/bin/coder-bar-hook")
    }

    private func deployStableHookBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: hookBin.path) else {
            throw NSError(
                domain: "CoderBar.HookInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "hook executable is missing: \(hookBin.path)"]
            )
        }

        let destination = stableHookBin
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path),
           FileManager.default.contentsEqual(atPath: hookBin.path, andPath: destination.path) {
            return
        }

        let staged = directory.appendingPathComponent(".coder-bar-hook.new-\(getpid())")
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.removeItem(at: staged)
        }
        try FileManager.default.copyItem(at: hookBin, to: staged)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: staged.path
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    // MARK: - Configure

    public func configure() throws -> Result {
        var r = Result()
        try deployStableHookBinary()

        if try configureClaude(&r) { r.installed.append("~/.claude/settings.json") }
        if try configureCodex(&r) { r.installed.append("~/.codex/hooks.json") }
        if try configureGemini(&r) { r.installed.append("~/.gemini/settings.json") }

        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) ||
            FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path) {
            // fine
        }
        return r
    }

    // MARK: - Deconfigure

    public func deconfigure() throws -> Result {
        var r = Result()
        if try deconfigureFile(at: home.appendingPathComponent(".claude/settings.json"), &r) {
            r.removed.append("~/.claude/settings.json")
        }
        if try deconfigureFile(at: home.appendingPathComponent(".codex/hooks.json"), &r) {
            r.removed.append("~/.codex/hooks.json")
        }
        if try deconfigureFile(at: home.appendingPathComponent(".gemini/settings.json"), &r) {
            r.removed.append("~/.gemini/settings.json")
        }
        return r
    }

    // MARK: - Individual agents

    private func configureClaude(_ r: inout Result) throws -> Bool {
        let url = home.appendingPathComponent(".claude/settings.json")
        let specs: [(category: String, timeout: Int, matcher: String?)] = [
            ("SessionStart", 30, "startup|resume|clear"),
            ("SessionEnd", 30, nil),
            ("UserPromptSubmit", 30, nil),
            ("PreToolUse", 86_400, "*"),
            ("PostToolUse", 15, "*"),
            ("PermissionRequest", 86_400, "*"),
            ("Notification", 5, "*"),
            ("PreCompact", 5, "manual|auto"),
            ("PostCompact", 5, "manual|auto"),
            ("SubagentStart", 30, nil),
            ("SubagentStop", 30, nil),
            ("Stop", 30, nil),
            ("StopFailure", 30, nil),
        ]
        let banner = specs.map {
            entry($0.category, source: "claude", timeout: $0.timeout, matcher: $0.matcher)
        }
        return try mergeInto(url, agentKey: "hooks", entries: banner, r: &r)
    }

    private func configureCodex(_ r: inout Result) throws -> Bool {
        let url = home.appendingPathComponent(".codex/hooks.json")
        let specs: [(category: String, timeout: Int, matcher: String?)] = [
            ("SessionStart", 5, "startup|resume|clear"),
            ("SessionEnd", 3, nil),
            ("UserPromptSubmit", 5, nil),
            ("PostToolUse", 5, ""),
            ("PermissionRequest", 7_200, nil),
            ("PreCompact", 5, "manual|auto"),
            ("PostCompact", 5, "manual|auto"),
            ("SubagentStart", 5, nil),
            ("SubagentStop", 5, nil),
            ("Stop", 5, nil),
        ]
        let banner = specs.map {
            entry($0.category, source: "codex", timeout: $0.timeout, matcher: $0.matcher)
        }
        return try mergeInto(url, agentKey: "hooks", entries: banner, r: &r)
    }

    private func configureGemini(_ r: inout Result) throws -> Bool {
        let url = home.appendingPathComponent(".gemini/settings.json")
        let categories = [
            "SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent",
            "BeforeTool", "AfterTool", "Notification",
        ]
        // Gemini hook timeouts are milliseconds.
        let banner = categories.map {
            entry($0, source: "gemini", timeout: 5_000, matcher: nil)
        }
        return try mergeInto(url, agentKey: "hooks", entries: banner, r: &r)
    }

    private func entry(_ category: String, source: String, timeout: Int, matcher: String?) -> String {
        let cmd = self.command(source, category)
        let matcherField = matcher.map { "\"matcher\":\(json($0))," } ?? ""
        // All three supported agents use an event-keyed array containing a
        // nested command hook. Only matcher presence and timeout units differ.
        return "{\(matcherField)\"hooks\":[{\"type\":\"command\",\"command\":\(json(cmd)),\"timeout\":\(timeout)}]}"
    }

    private func json(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    // MARK: - Merge helper

    private func mergeInto(_ url: URL, agentKey: String, entries: [String], r: inout Result) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Directory exists? Only install when config already present to avoid
            // creating configs the user never asked for.
            if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                r.skipped.append(url.lastPathComponent + " (no config dir)")
                return false
            }
            try backupIfNeeded(url, r: &r)
            var root: [String: Any] = [agentKey: [String: Any]()]
            try mergeEntries(into: &root, agentKey: agentKey, entries: entries)
            try writeJSON(root, to: url)
            return true
        }
        try backupIfNeeded(url, r: &r)
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CoderBar.HookInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "agent config is not a JSON object: \(url.path)"]
            )
        }
        try mergeEntries(into: &root, agentKey: agentKey, entries: entries)
        try writeJSON(root, to: url)
        return true
    }

    private func mergeEntries(into root: inout [String: Any], agentKey: String, entries: [String]) throws {
        var hooks = (root[agentKey] as? [String: Any]) ?? [:]
        try mergeEntriesRaw(into: &hooks, entries: entries)
        root[agentKey] = hooks
    }

    private func mergeEntriesRaw(into hooks: inout [String: Any], entries: [String]) throws {
        removeManagedEntries(from: &hooks)

        for e in entries {
            guard let obj = try JSONSerialization.jsonObject(with: Data(e.utf8)) as? [String: Any],
                  let command = hookCommands(in: obj).first,
                  let category = commandCategory(for: command)
            else {
                throw NSError(
                    domain: "CoderBar.HookInstaller",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "generated hook entry is invalid: \(e)"]
                )
            }
            // Agent configs are keyed by lifecycle event name. A matcher,
            // when present, belongs inside that event's array item.
            addCategory(&hooks, key: category, entry: obj)
        }
    }

    private func removeManagedEntries(from hooks: inout [String: Any]) {
        for (key, value) in hooks {
            guard let items = value as? [[String: Any]] else { continue }
            var cleanedItems: [[String: Any]] = []

            for var item in items {
                if var nestedHooks = item["hooks"] as? [[String: Any]] {
                    nestedHooks.removeAll { nested in
                        guard let command = nested["command"] as? String else { return false }
                        return isManagedCommand(command)
                    }
                    guard !nestedHooks.isEmpty else { continue }
                    item["hooks"] = nestedHooks
                    cleanedItems.append(item)
                    continue
                }

                if let command = item["command"] as? String,
                   isManagedCommand(command) {
                    continue
                }
                cleanedItems.append(item)
            }

            if cleanedItems.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = cleanedItems
            }
        }
    }

    private func isManagedCommand(_ command: String) -> Bool {
        command.contains(hookBin.path)
            || command.contains(stableHookBin.path)
            || command.contains("coder-bar-hook --source")
    }

    private func commandCategory(for cmd: String) -> String? {
        // "…/coder-bar-hook --source X --category Y"
        let parts = cmd.components(separatedBy: "--category ")
        if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    private func addCategory(_ hooks: inout [String: Any], key: String, entry: [String: Any]) {
        let existing = (hooks[key] as? [[String: Any]]) ?? []
        let merged = existing + [entry]
        hooks[key] = merged
    }

    // MARK: - Deconfigure helper

    private func deconfigureFile(at url: URL, _ r: inout Result) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CoderBar.HookInstaller",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "agent config is not a JSON object: \(url.path)"]
            )
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return false }

        let before = try JSONSerialization.data(withJSONObject: hooks, options: [.sortedKeys])
        removeManagedEntries(from: &hooks)
        let after = try JSONSerialization.data(withJSONObject: hooks, options: [.sortedKeys])
        let changed = before != after
        if changed {
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
            try backupIfNeeded(url, r: &r)
            try writeJSON(root, to: url)
            return true
        }
        return false
    }

    private func hookCommands(in item: [String: Any]) -> [String] {
        if let hooks = item["hooks"] as? [[String: Any]] {
            return hooks.compactMap { $0["command"] as? String }
        }
        if let cmd = item["command"] as? String {
            return [cmd]
        }
        return []
    }

    // MARK: - Backup & write

    private func backupIfNeeded(_ url: URL, r: inout Result) throws {
        let bak = url.path + ".coderbar.bak"
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: bak) else { return }
        try FileManager.default.copyItem(atPath: url.path, toPath: bak)
        r.backups.append(bak)
    }

    private func writeJSON(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
