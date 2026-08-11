import Foundation
import CoderBarKit

// coder-bar-hook
//
// Invoked by agent hook systems (Claude Code, Codex, Gemini CLI) with the
// hook JSON payload on stdin. It forwards a {source, category, payload}
// frame to the menu-bar app over 127.0.0.1. Interactive hooks wait for an
// explicit reply file written by the app; ordinary lifecycle hooks return
// immediately.

signal(SIGPIPE, SIG_IGN)
setbuf(stdin, nil)

var source: String?
var category: String?

let args = ProcessInfo.processInfo.arguments
var i = 0
while i < args.count {
    switch args[i] {
    case "--source" where i + 1 < args.count:
        source = args[i + 1]; i += 2
    case "--category" where i + 1 < args.count:
        category = args[i + 1]; i += 2
    default:
        i += 1
    }
}

if source == nil, let env = ProcessInfo.processInfo.environment["CODERBAR_SOURCE"], !env.isEmpty {
    source = env
}
if category == nil, let env = ProcessInfo.processInfo.environment["CODERBAR_CATEGORY"], !env.isEmpty {
    category = env
}

let input = FileHandle.standardInput.readDataToEndOfFile()
var payload: [String: Any]?
if !input.isEmpty {
    do {
        guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw HookForwardError.invalidPayload("hook stdin is not a JSON object")
        }
        payload = object
    } catch {
        reportFailure("invalid hook payload: \(error)")
    }
}

var frame: [String: Any] = [:]
if let s = source { frame["source"] = s }
if let c = category { frame["category"] = c }
var enriched = payload ?? [:]
let environment = ProcessInfo.processInfo.environment
let invocationID = UUID().uuidString

if let envPwd = environment["PWD"], enriched["cwd"] == nil {
    enriched["cwd"] = envPwd
}
if enriched["hook_event_name"] == nil {
    enriched["hook_event_name"] = category ?? "event"
}
// Use an app-owned, path-safe correlation id even if an agent provides its
// own tool id. The original tool id remains available as `tool_use_id`.
enriched["invocation_id"] = invocationID
if let value = environment["__CFBundleIdentifier"], !value.isEmpty {
    enriched["terminal_bundle_id"] = value
}
if let value = environment["TERM_PROGRAM"], !value.isEmpty {
    enriched["term_program"] = value
}
if let value = environment["TERM_SESSION_ID"], !value.isEmpty {
    enriched["term_session_id"] = value
}
if let value = environment["TMUX_PANE"], !value.isEmpty {
    enriched["tmux_pane"] = value
}
if let value = environment["CODEX_THREAD_ID"], !value.isEmpty {
    enriched["codex_thread_id"] = value
}
enriched["parent_pid"] = Int(getppid())
frame["payload"] = enriched

var forwarded = false
do {
    guard source != nil else { throw HookForwardError.missingArgument("source") }
    guard category != nil else { throw HookForwardError.missingArgument("category") }
    let data = try JSONSerialization.data(withJSONObject: frame)
    try sendToApp(data)
    forwarded = true
} catch {
    reportFailure("forward failed: \(error)")
}

if forwarded, isInteractiveHook(source: source, category: category, payload: enriched) {
    do {
        let response = try waitForReply(invocationID: invocationID, source: source)
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(0)
    } catch {
        // Returning no decision hands control back to the agent's native UI.
        // The failure is logged so it cannot masquerade as an accepted action.
        reportFailure("interactive reply unavailable for \(invocationID): \(error)")
    }
}

print("{}")
exit(0)

// MARK: - Transport

private enum HookForwardError: LocalizedError {
    case invalidPayload(String)
    case missingArgument(String)
    case invalidPort(String)
    case posix(operation: String, code: Int32)
    case connectionClosed
    case replyTimedOut
    case invalidReply(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let detail):
            return detail
        case .missingArgument(let name):
            return "missing --\(name)"
        case .invalidPort(let value):
            return "invalid event server port: \(value)"
        case .posix(let operation, let code):
            return "\(operation): \(String(cString: strerror(code))) (errno \(code))"
        case .connectionClosed:
            return "event server closed the socket before the frame was written"
        case .replyTimedOut:
            return "timed out waiting for the island response"
        case .invalidReply(let detail):
            return "invalid island response: \(detail)"
        }
    }
}

private func isInteractiveHook(
    source: String?,
    category: String?,
    payload: [String: Any]
) -> Bool {
    let event = (category ?? payload["hook_event_name"] as? String ?? "").lowercased()
    if source == "claude", !shouldHandleClaudeInteractions() { return false }
    if event == "permissionrequest" { return source == "claude" || source == "codex" }
    guard source == "claude", event == "pretooluse" else { return false }
    let tool = (payload["tool_name"] as? String ?? "").lowercased()
    return tool == "askuserquestion" || tool == "exitplanmode"
}

private func shouldHandleClaudeInteractions() -> Bool {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coderbar/preferences.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = object["handle_claude_interactions"] as? Bool
    else { return true }
    return value
}

private func waitForReply(invocationID: String, source: String?) throws -> Data {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coderbar/replies", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let replyURL = directory.appendingPathComponent("\(invocationID).json")
    let configuredTimeout = ProcessInfo.processInfo.environment["CODERBAR_RESPONSE_TIMEOUT"]
        .flatMap(TimeInterval.init)
    let timeout = configuredTimeout ?? (source == "codex" ? 7_100 : 86_300)
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if FileManager.default.fileExists(atPath: replyURL.path) {
            let data = try Data(contentsOf: replyURL)
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else {
                throw HookForwardError.invalidReply("top level is not a JSON object")
            }
            do {
                try FileManager.default.removeItem(at: replyURL)
            } catch {
                reportFailure("could not remove consumed reply \(replyURL.path): \(error)")
            }
            return data
        }
        usleep(100_000)
    }
    throw HookForwardError.replyTimedOut
}

private func sendToApp(_ data: Data) throws {
    let port = try resolvePort()

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw HookForwardError.posix(operation: "socket", code: errno)
    }
    defer { close(fd) }

    var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
    guard setsockopt(
        fd,
        SOL_SOCKET,
        SO_SNDTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else {
        throw HookForwardError.posix(operation: "setsockopt", code: errno)
    }

    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
            Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else {
        throw HookForwardError.posix(
            operation: "connect 127.0.0.1:\(port)",
            code: errno
        )
    }

    var line = data
    line.append(0x0A)
    try line.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var written = 0
        while written < buffer.count {
            let count = Darwin.write(
                fd,
                baseAddress.advanced(by: written),
                buffer.count - written
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw HookForwardError.posix(operation: "write", code: errno)
            }
            guard count > 0 else { throw HookForwardError.connectionClosed }
            written += count
        }
    }
}

private func resolvePort() throws -> UInt16 {
    if let env = ProcessInfo.processInfo.environment["CODERBAR_PORT"] {
        guard let port = UInt16(env) else {
            throw HookForwardError.invalidPort(env)
        }
        return port
    }
    let portFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coderbar/port")
    if FileManager.default.fileExists(atPath: portFile.path) {
        let value = try String(contentsOf: portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(value) else {
            throw HookForwardError.invalidPort(value)
        }
        return port
    }
    return 41_734
}

private func reportFailure(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let stderrData = line.data(using: .utf8) {
        FileHandle.standardError.write(stderrData)
    }

    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coderbar", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        let fallback = "CoderBar could not create hook log directory: \(error)\n"
        if let data = fallback.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        return
    }

    let logPath = directory.appendingPathComponent("hook-errors.log").path
    let logFD = Darwin.open(logPath, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
    guard logFD >= 0 else {
        let fallback = "CoderBar could not open hook error log: \(String(cString: strerror(errno)))\n"
        if let data = fallback.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        return
    }
    defer { Darwin.close(logFD) }

    line.withCString { pointer in
        let result = Darwin.write(logFD, pointer, strlen(pointer))
        if result < 0 {
            let fallback = "CoderBar could not write hook error log: \(String(cString: strerror(errno)))\n"
            if let data = fallback.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }
}
