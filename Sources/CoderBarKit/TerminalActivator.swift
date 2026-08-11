import Foundation
import AppKit

public enum TerminalActivator {
    public enum ActivationResult: Equatable {
        case activated(appName: String, precise: Bool)
        case unavailable(reason: String)

        public var message: String {
            switch self {
            case .activated(let appName, let precise):
                return precise
                    ? "已跳转到 \(appName) 的对应会话"
                    : "已打开 \(appName)；当前事件没有精确窗口标识"
            case .unavailable(let reason):
                return reason
            }
        }

        public var succeeded: Bool {
            if case .activated = self { return true }
            return false
        }
    }

    private struct Target {
        let bundleID: String
        let name: String
    }

    private static let terminalTargets: [Target] = [
        .init(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        .init(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        .init(bundleID: "com.apple.Terminal", name: "Terminal"),
        .init(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        .init(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
        .init(bundleID: "net.kovidgoyal.kitty", name: "Kitty"),
        .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
    ]

    @discardableResult
    public static func activate(
        _ session: SessionStore.Session,
        allowCodexDeepLink: Bool = true
    ) -> ActivationResult {
        if session.source == "codex", allowCodexDeepLink,
           let threadID = session.codexThreadID ?? session.sessionId,
           !threadID.isEmpty {
            let escaped = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? threadID
            if let url = URL(string: "codex://threads/\(escaped)"),
               NSWorkspace.shared.open(url) {
                return .activated(appName: "Codex", precise: true)
            }
            NSLog(
                "CoderBar Codex deep-link activation failed: session=%@ thread=%@",
                session.sessionId ?? "missing",
                threadID
            )
        }

        if session.source == "codex",
           session.dataOrigin == "codex-desktop",
           !allowCodexDeepLink {
            return .unavailable(reason: "设置已关闭 Codex App 会话跳转")
        }

        if session.source == "claude_desktop",
           session.dataOrigin != "claude-desktop",
           let conversationID = session.conversationID,
           let result = openClaudeConversation(conversationID) {
            return result
        }

        if (session.source == "claude" || session.dataOrigin == "claude-desktop"),
           session.terminalBundleID == "com.anthropic.claudefordesktop",
           let desktopSessionID = session.conversationID ?? session.sessionId,
           let result = openClaudeCodeDesktopSession(desktopSessionID) {
            return result
        }

        let candidates = targets(for: session)
        for target in candidates {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == target.bundleID
            }) else {
                continue
            }

            let didActivate = app.activate(options: [.activateAllWindows])
            guard didActivate else {
                let result = ActivationResult.unavailable(
                    reason: "找到了 \(target.name)，但 macOS 拒绝激活它"
                )
                NSLog("CoderBar session activation failed: %@", result.message)
                return result
            }

            // The current hook contract identifies an app and session, but it
            // does not yet provide a supported per-window deep link.
            return .activated(appName: target.name, precise: false)
        }

        let names = candidates.map(\.name).joined(separator: "、")
        let result = ActivationResult.unavailable(
            reason: names.isEmpty
                ? "这个 session 没有可用的应用定位信息"
                : "没有找到正在运行的目标应用：\(names)"
        )
        NSLog(
            "CoderBar session activation unavailable: source=%@ session=%@ reason=%@",
            session.source,
            session.sessionId ?? "missing",
            result.message
        )
        return result
    }

    public static func targetDisplayName(for session: SessionStore.Session) -> String {
        if session.source == "codex", session.dataOrigin == "codex-desktop" {
            return "Codex"
        }
        if session.dataOrigin == "claude-desktop"
            || session.terminalBundleID == "com.anthropic.claudefordesktop" {
            return "Claude"
        }
        if let bundleID = session.terminalBundleID,
           let target = knownTarget(bundleID: bundleID) {
            return target.name
        }
        if let termProgram = session.termProgram,
           let target = targetForTermProgram(termProgram) {
            return target.name
        }
        return AgentNames.display(session.source)
    }

    public static func hasPreciseJumpTarget(_ session: SessionStore.Session) -> Bool {
        if session.source == "codex" {
            return (session.codexThreadID ?? session.sessionId)?.isEmpty == false
        }
        if session.dataOrigin == "claude-desktop"
            || session.terminalBundleID == "com.anthropic.claudefordesktop" {
            return (session.conversationID ?? session.sessionId)?.isEmpty == false
        }
        return false
    }

    private static func openClaudeConversation(_ conversationID: String) -> ActivationResult? {
        let escaped = conversationID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? conversationID
        guard let url = URL(string: "claude://claude.ai/chat/\(escaped)") else {
            return nil
        }
        guard NSWorkspace.shared.open(url) else {
            NSLog(
                "CoderBar Claude conversation deep-link failed: conversation=%@",
                conversationID
            )
            return nil
        }
        return .activated(appName: "Claude", precise: true)
    }

    private static func openClaudeCodeDesktopSession(_ sessionID: String) -> ActivationResult? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/\(sessionID)"
        guard let url = components.url else { return nil }
        guard NSWorkspace.shared.open(url) else {
            NSLog(
                "CoderBar Claude App code deep-link failed: session=%@",
                sessionID
            )
            return nil
        }
        return .activated(appName: "Claude", precise: true)
    }

    private static func targets(for session: SessionStore.Session) -> [Target] {
        var result: [Target] = []

        if let bundleID = session.terminalBundleID,
           !bundleID.isEmpty,
           let target = knownTarget(bundleID: bundleID) {
            result.append(target)
        }

        if let termProgram = session.termProgram,
           let target = targetForTermProgram(termProgram),
           !result.contains(where: { $0.bundleID == target.bundleID }) {
            result.append(target)
        }

        let sourceTarget: Target?
        switch session.source {
        case "codex":
            sourceTarget = .init(bundleID: "com.openai.codex", name: "Codex")
        case "claude", "claude_desktop":
            sourceTarget = .init(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
        default:
            sourceTarget = nil
        }
        if let sourceTarget,
           !result.contains(where: { $0.bundleID == sourceTarget.bundleID }) {
            result.append(sourceTarget)
        }

        for terminal in terminalTargets where !result.contains(where: { $0.bundleID == terminal.bundleID }) {
            result.append(terminal)
        }
        return result
    }

    private static func knownTarget(bundleID: String) -> Target? {
        if bundleID == "com.openai.codex" {
            return .init(bundleID: bundleID, name: "Codex")
        }
        if bundleID == "com.anthropic.claudefordesktop" {
            return .init(bundleID: bundleID, name: "Claude")
        }
        return terminalTargets.first { $0.bundleID == bundleID }
            ?? .init(bundleID: bundleID, name: bundleID)
    }

    private static func targetForTermProgram(_ value: String) -> Target? {
        let normalized = value.lowercased()
        if normalized.contains("ghostty") { return knownTarget(bundleID: "com.mitchellh.ghostty") }
        if normalized.contains("iterm") { return knownTarget(bundleID: "com.googlecode.iterm2") }
        if normalized.contains("apple_terminal") || normalized == "terminal" {
            return knownTarget(bundleID: "com.apple.Terminal")
        }
        if normalized.contains("warp") { return knownTarget(bundleID: "dev.warp.Warp-Stable") }
        if normalized.contains("wezterm") { return knownTarget(bundleID: "com.github.wez.wezterm") }
        if normalized.contains("kitty") { return knownTarget(bundleID: "net.kovidgoyal.kitty") }
        if normalized.contains("vscode") { return knownTarget(bundleID: "com.microsoft.VSCode") }
        return nil
    }
}
