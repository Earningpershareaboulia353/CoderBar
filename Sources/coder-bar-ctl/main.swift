import Foundation
import CoderBarKit

// coder-bar-ctl configure|deconfigure|status|discover [--home PATH] [--port N]

let args = ProcessInfo.processInfo.arguments
guard args.count >= 2 else {
    print("usage: coder-bar-ctl configure|deconfigure|status|discover [--home PATH] [--port N]")
    exit(2)
}

let command = args[1]
var home: URL = FileManager.default.homeDirectoryForCurrentUser
var port: UInt16 = 41_734

var i = 2
while i < args.count {
    switch args[i] {
    case "--home" where i + 1 < args.count:
        home = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        i += 2
    case "--port" where i + 1 < args.count:
        if let n = UInt16(args[i + 1]) { port = n }
        i += 2
    default:
        i += 1
    }
}

let hookBin = Bundle.main.executableURL?
    .deletingLastPathComponent()
    .appendingPathComponent("coder-bar-hook")
    ?? home.appendingPathComponent("CoderBar/dist/bin/coder-bar-hook")

let installer = HookInstaller(home: home, hookBin: hookBin, port: port)

do {
    switch command {
    case "configure":
        let r = try installer.configure()
        print(r)
    case "deconfigure":
        let r = try installer.deconfigure()
        print(r)
    case "status":
        for file in [".claude/settings.json", ".codex/hooks.json", ".gemini/settings.json"] {
            let url = home.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .utf8) {
                let has = str.contains("coder-bar-hook")
                print("\(file): \(has ? "INSTALLED" : "not configured")")
            } else {
                print("\(file): missing")
            }
        }
    case "discover":
        let report = DesktopSessionDiscovery.scan(home: home)
        for session in report.sessions.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) {
            let rawTitle = session.title
                ?? (session.cwd as NSString?)?.lastPathComponent
                ?? session.sessionID
            let oneLineTitle = rawTitle
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            let title = oneLineTitle.count > 80
                ? String(oneLineTitle.prefix(80)) + "…"
                : oneLineTitle
            let model = [session.model, session.reasoningEffort]
                .compactMap { $0 }
                .joined(separator: " · ")
            print("\(session.source) | \(session.statusText) | \(title) | \(model) | \(session.sessionID)")
            for child in session.childAgents {
                let name = child.nickname ?? child.role ?? child.id
                let childModel = [child.model, child.reasoningEffort]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                print("  agent | \(child.statusText) | \(name) | \(childModel) | \(child.id)")
            }
        }
        print("desktop sessions: \(report.sessions.count)")
        if !report.warnings.isEmpty {
            for warning in report.warnings {
                fputs("warning: \(warning)\n", stderr)
            }
            exit(1)
        }
    default:
        print("unknown command: \(command)")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
