import SwiftUI
import UserNotifications
import CoderBarKit

@MainActor
final class AppModel: ObservableObject {
    static let shared: AppModel = AppModel()

    @Published var isTracking = false
    @Published var serverPort: UInt16 = 0
    @Published var serverError: String?
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notifications") }
    }
    @Published var hooksConfigured = false
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }
    @Published var displayTargetID: String {
        didSet {
            UserDefaults.standard.set(displayTargetID, forKey: "displayTargetID")
            islandController?.displayTargetDidChange()
        }
    }
    @Published var autoExpandOnAlert: Bool {
        didSet { UserDefaults.standard.set(autoExpandOnAlert, forKey: "autoExpandOnAlert") }
    }
    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }
    @Published var hoverToExpand: Bool {
        didSet { UserDefaults.standard.set(hoverToExpand, forKey: "hoverToExpand") }
    }
    @Published var autoCollapseOnMouseLeave: Bool {
        didSet {
            UserDefaults.standard.set(autoCollapseOnMouseLeave, forKey: "autoCollapseOnMouseLeave")
        }
    }
    @Published var hoverDelaySeconds: Double {
        didSet { UserDefaults.standard.set(hoverDelaySeconds, forKey: "hoverDelaySeconds") }
    }
    @Published var alertDwellSeconds: Double {
        didSet { UserDefaults.standard.set(alertDwellSeconds, forKey: "alertDwellSeconds") }
    }
    @Published var completionPresentation: String {
        didSet { UserDefaults.standard.set(completionPresentation, forKey: "completionPresentation") }
    }
    @Published var panelWidth: Double {
        didSet {
            UserDefaults.standard.set(panelWidth, forKey: "panelWidth")
            islandController?.refreshLayout(animated: false)
        }
    }
    @Published var maxPanelHeight: Double {
        didSet {
            UserDefaults.standard.set(maxPanelHeight, forKey: "maxPanelHeight")
            islandController?.refreshLayout(animated: false)
        }
    }
    @Published var contentFontSize: Double {
        didSet { UserDefaults.standard.set(contentFontSize, forKey: "contentFontSize") }
    }
    @Published var showProjectName: Bool {
        didSet { UserDefaults.standard.set(showProjectName, forKey: "showProjectName") }
    }
    @Published var showModel: Bool {
        didSet { UserDefaults.standard.set(showModel, forKey: "showModel") }
    }
    @Published var showReasoningEffort: Bool {
        didSet { UserDefaults.standard.set(showReasoningEffort, forKey: "showReasoningEffort") }
    }
    @Published var showTasks: Bool {
        didSet {
            UserDefaults.standard.set(showTasks, forKey: "showTasks")
            islandController?.refreshLayout(animated: false)
        }
    }
    @Published var showSubagents: Bool {
        didSet {
            UserDefaults.standard.set(showSubagents, forKey: "showSubagents")
            islandController?.refreshLayout(animated: false)
        }
    }
    @Published var showActivity: Bool {
        didSet { UserDefaults.standard.set(showActivity, forKey: "showActivity") }
    }
    @Published var showUsage: Bool {
        didSet { UserDefaults.standard.set(showUsage, forKey: "showUsage") }
    }
    @Published var usageShowsRemaining: Bool {
        didSet { UserDefaults.standard.set(usageShowsRemaining, forKey: "usageShowsRemaining") }
    }
    @Published var soundVolume: Double {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") }
    }
    @Published var soundOnStart: Bool {
        didSet { UserDefaults.standard.set(soundOnStart, forKey: "soundOnStart") }
    }
    @Published var soundOnCompletion: Bool {
        didSet { UserDefaults.standard.set(soundOnCompletion, forKey: "soundOnCompletion") }
    }
    @Published var soundOnApproval: Bool {
        didSet { UserDefaults.standard.set(soundOnApproval, forKey: "soundOnApproval") }
    }
    @Published var panelShortcutsEnabled: Bool {
        didSet { UserDefaults.standard.set(panelShortcutsEnabled, forKey: "panelShortcutsEnabled") }
    }
    @Published var codexApprovalMode: String {
        didSet { UserDefaults.standard.set(codexApprovalMode, forKey: "codexApprovalMode") }
    }
    @Published var claudeNativeApprovals: Bool {
        didSet {
            UserDefaults.standard.set(claudeNativeApprovals, forKey: "claudeNativeApprovals")
            writeHookPreferences()
        }
    }
    @Published var openAppServerSessionsInCodex: Bool {
        didSet {
            UserDefaults.standard.set(openAppServerSessionsInCodex, forKey: "openAppServerSessionsInCodex")
        }
    }
    @Published var betaUpdates: Bool {
        didSet { UserDefaults.standard.set(betaUpdates, forKey: "betaUpdates") }
    }
    @Published private(set) var interactionErrors: [String: String] = [:]
    @Published private(set) var desktopDiscoveryWarning: String?
    @Published private(set) var desktopSessionCount = 0
    @Published var showOnboarding = false

    @Published private(set) var store: SessionStore?
    @Published private(set) var islandController: NotchPanelController?

    private var server: EventServer?
    private var desktopSessionMonitor: Task<Void, Never>?
    private let notifier = Notifier()
    private let dataDir: URL

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var bundleID: String {
        Bundle.main.bundleIdentifier ?? "dev.coderbar.app"
    }

    struct DisplayTargetOption: Identifiable, Hashable {
        let id: String
        let title: String
    }

    var displayTargetOptions: [DisplayTargetOption] {
        var options = [
            DisplayTargetOption(id: "main", title: "主显示器"),
            DisplayTargetOption(id: "focus", title: "跟随焦点"),
        ]
        options.append(contentsOf: NSScreen.screens.map { screen in
            DisplayTargetOption(
                id: "screen:\(Self.screenIdentifier(screen))",
                title: screen.localizedName
            )
        })
        return options
    }

    static func screenIdentifier(_ screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        NSLog("CoderBar screen has no NSScreenNumber: %@", screen.localizedName)
        return screen.localizedName
    }

    private init() {
        if let override = ProcessInfo.processInfo.environment["CODERBAR_DATA_DIR"],
           !override.isEmpty {
            dataDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CoderBar")
        }
        let d = UserDefaults.standard
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        notificationsEnabled = d.object(forKey: "notifications") == nil
            ? true : d.bool(forKey: "notifications")
        displayTargetID = d.string(forKey: "displayTargetID") ?? "main"
        autoExpandOnAlert = d.object(forKey: "autoExpandOnAlert") == nil
            ? true : d.bool(forKey: "autoExpandOnAlert")
        soundsEnabled = d.object(forKey: "soundsEnabled") == nil
            ? true : d.bool(forKey: "soundsEnabled")
        hoverToExpand = d.object(forKey: "hoverToExpand") == nil
            ? true : d.bool(forKey: "hoverToExpand")
        autoCollapseOnMouseLeave = d.object(forKey: "autoCollapseOnMouseLeave") == nil
            ? true : d.bool(forKey: "autoCollapseOnMouseLeave")
        hoverDelaySeconds = d.object(forKey: "hoverDelaySeconds") == nil
            ? 0.15 : d.double(forKey: "hoverDelaySeconds")
        alertDwellSeconds = d.object(forKey: "alertDwellSeconds") == nil
            ? 5 : d.double(forKey: "alertDwellSeconds")
        completionPresentation = d.string(forKey: "completionPresentation") ?? "glance"
        panelWidth = d.object(forKey: "panelWidth") == nil ? 650 : d.double(forKey: "panelWidth")
        maxPanelHeight = d.object(forKey: "maxPanelHeight") == nil
            ? 482 : d.double(forKey: "maxPanelHeight")
        contentFontSize = d.object(forKey: "contentFontSize") == nil
            ? 11 : d.double(forKey: "contentFontSize")
        showProjectName = d.object(forKey: "showProjectName") == nil
            ? true : d.bool(forKey: "showProjectName")
        showModel = d.object(forKey: "showModel") == nil ? true : d.bool(forKey: "showModel")
        showReasoningEffort = d.object(forKey: "showReasoningEffort") == nil
            ? true : d.bool(forKey: "showReasoningEffort")
        showTasks = d.object(forKey: "showTasks") == nil ? true : d.bool(forKey: "showTasks")
        showSubagents = d.object(forKey: "showSubagents") == nil
            ? true : d.bool(forKey: "showSubagents")
        showActivity = d.object(forKey: "showActivity") == nil
            ? true : d.bool(forKey: "showActivity")
        showUsage = d.object(forKey: "showUsage") == nil ? true : d.bool(forKey: "showUsage")
        usageShowsRemaining = d.bool(forKey: "usageShowsRemaining")
        soundVolume = d.object(forKey: "soundVolume") == nil ? 0.7 : d.double(forKey: "soundVolume")
        soundOnStart = d.object(forKey: "soundOnStart") == nil
            ? true : d.bool(forKey: "soundOnStart")
        soundOnCompletion = d.object(forKey: "soundOnCompletion") == nil
            ? true : d.bool(forKey: "soundOnCompletion")
        soundOnApproval = d.object(forKey: "soundOnApproval") == nil
            ? true : d.bool(forKey: "soundOnApproval")
        panelShortcutsEnabled = d.object(forKey: "panelShortcutsEnabled") == nil
            ? true : d.bool(forKey: "panelShortcutsEnabled")
        codexApprovalMode = d.string(forKey: "codexApprovalMode") ?? "followFocus"
        claudeNativeApprovals = d.object(forKey: "claudeNativeApprovals") == nil
            ? true : d.bool(forKey: "claudeNativeApprovals")
        openAppServerSessionsInCodex = d.object(forKey: "openAppServerSessionsInCodex") == nil
            ? true : d.bool(forKey: "openAppServerSessionsInCodex")
        betaUpdates = d.bool(forKey: "betaUpdates")
        do {
            try FileManager.default.createDirectory(
                at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".coderbar"),
                withIntermediateDirectories: true
            )
        } catch {
            serverError = "无法创建 Hook 状态目录：\(error.localizedDescription)"
            NSLog("could not create hook state directory: \(error)")
        }
        writeHookPreferences()
        do {
            try startServer()
        } catch {
            serverError = "\(error)"
            NSLog("could not start event server: \(error)")
        }
        notifier.requestAuthorization()
        refreshHooksState()
        showOnboarding = !hooksConfigured
        if launchAtLogin { installLaunchAgent() }
        islandController = NotchPanelController(model: self)
        startDesktopSessionDiscovery()
    }

    private func startServer() throws {
        var lastError: Error?
        for port in UInt16(41_734)...UInt16(41_742) {
            do {
                try startOn(port)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "AppModel", code: 1)
    }

    private func startOn(_ port: UInt16) throws {
        let store = try SessionStore(dataDir: dataDir)
        self.store = store
        let server = try EventServer(port: port) { payload in
            Task { @MainActor in
                AppModel.shared.handle(payload)
            }
        } onReady: { boundPort in
            let portFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".coderbar/port")
            do {
                try String(boundPort).write(to: portFile, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    AppModel.shared.serverPort = boundPort
                    AppModel.shared.isTracking = true
                }
            } catch {
                NSLog("could not publish event server port: \(error)")
                let message = error.localizedDescription
                Task { @MainActor in
                    AppModel.shared.serverError = "Hook 端口文件写入失败：\(message)"
                    AppModel.shared.isTracking = false
                }
            }
        }
        server.start()
        self.server = server
        serverPort = server.port
    }

    func shutdown() {
        desktopSessionMonitor?.cancel()
        desktopSessionMonitor = nil
        server?.stop()
        server = nil
        islandController?.shutdown()
        islandController = nil
        isTracking = false
    }

    private func handle(_ payload: HookPayload) {
        guard let store else {
            NSLog("CoderBar dropped a Hook event because SessionStore is unavailable")
            return
        }
        store.ingest(payload)
        islandController?.island.sessionsDidChange()
        islandController?.refreshLayout()

        let cat = (payload.category ?? payload.hookEventName ?? "").lowercased()
        let isAlert = PendingInteraction.fromHook(payload) != nil
            || cat == "permissionrequest" || cat == "askuserquestion"
            || (cat == "notification"
                && payload.hookMessageName?.lowercased().contains("permission") == true)

        if isAlert {
            if payload.source == "codex", codexApprovalMode == "silent" {
                return
            }
            islandController?.island.onAlert()
            if soundsEnabled && soundOnApproval { SoundManager.play(.alert, volume: soundVolume) }
            if autoExpandOnAlert
                && !(payload.source == "codex" && codexApprovalMode == "notify") {
                islandController?.island.expand(transient: true)
            }
            if notificationsEnabled {
                notifier.notifyIfNeeded(payload)
            }
        } else if cat == "sessionstart" {
            if soundsEnabled && soundOnStart { SoundManager.play(.start, volume: soundVolume) }
        } else if cat == "sessionend" || cat == "preexit" {
            if soundsEnabled && soundOnCompletion { SoundManager.play(.end, volume: soundVolume) }
            let logicalSessionID = payload.parentSessionID ?? payload.resolvedSessionID
            if cat == "sessionend", let session = store.sessions.first(where: {
                $0.id == "\(payload.source ?? "unknown")|\(logicalSessionID)"
            }) {
                islandController?.island.showCompletion(session)
                if completionPresentation == "expand" {
                    islandController?.island.expand(transient: true)
                }
            }
        }
    }

    // MARK: - Desktop app sessions

    private func startDesktopSessionDiscovery() {
        desktopSessionMonitor?.cancel()
        if ProcessInfo.processInfo.environment["CODERBAR_DEBUG_DISABLE_DESKTOP_DISCOVERY"] != nil {
            NSLog("CoderBar desktop session discovery disabled by debug environment")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        desktopSessionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                let report = await Task.detached(priority: .utility) {
                    DesktopSessionDiscovery.scan(home: home)
                }.value

                guard let self else { return }
                applyDesktopDiscovery(report)

                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func applyDesktopDiscovery(_ report: DesktopSessionDiscovery.Report) {
        guard let store else {
            let message = "桌面会话发现成功，但 SessionStore 不可用"
            if desktopDiscoveryWarning != message {
                NSLog("CoderBar %@", message)
            }
            desktopDiscoveryWarning = message
            return
        }

        let sessionsChanged = store.synchronizeDesktopSessions(report.sessions)
        if desktopSessionCount != report.sessions.count {
            desktopSessionCount = report.sessions.count
        }

        let warning = report.warnings.isEmpty
            ? nil
            : report.warnings.joined(separator: "\n")
        if warning != desktopDiscoveryWarning {
            if let warning {
                NSLog("CoderBar desktop discovery warning: %@", warning)
            }
            desktopDiscoveryWarning = warning
        }
        if sessionsChanged {
            islandController?.island.sessionsDidChange()
            islandController?.refreshLayout()
        }
    }

    // MARK: - Hooks

    var hookBinURL: URL {
        if let app = Bundle.main.executableURL {
            let candidates = [
                app.deletingLastPathComponent().appendingPathComponent("coder-bar-hook"),
                app.deletingLastPathComponent().appendingPathComponent("bin/coder-bar-hook"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("CoderBar/dist/bin/coder-bar-hook"),
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c.path) {
                return c
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CoderBar/dist/bin/coder-bar-hook")
    }

    func configureHooks() {
        do {
            let installer = HookInstaller(hookBin: hookBinURL, port: serverPort)
            print(try installer.configure())
            refreshHooksState()
        } catch {
            serverError = "hooks: \(error)"
        }
    }

    func deconfigureHooks() {
        do {
            let installer = HookInstaller(hookBin: hookBinURL, port: serverPort)
            print(try installer.deconfigure())
            refreshHooksState()
        } catch {
            serverError = "hooks: \(error)"
        }
    }

    func refreshHooksState() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        hooksConfigured = [".claude/settings.json", ".codex/hooks.json", ".gemini/settings.json"]
            .compactMap { try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8) }
            .contains { $0.contains("coder-bar-hook") }
    }

    private func writeHookPreferences() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coderbar/preferences.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "handle_claude_interactions": claudeNativeApprovals,
            ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            serverError = "Hook 偏好写入失败：\(error.localizedDescription)"
            NSLog("CoderBar could not write hook preferences: %@", String(describing: error))
        }
    }

    // MARK: - UI helpers

    func openDataFolder() {
        NSWorkspace.shared.open(dataDir)
    }

    func testNotification() {
        notifier.post(title: "CoderBar", body: "Test notification — notifications are working.")
    }

    func respond(
        sessionID: String,
        interaction: PendingInteraction,
        allow: Bool,
        answers: [String: [String]] = [:]
    ) {
        guard interaction.canRespond else {
            interactionErrors[sessionID] = "这个请求来自桌面会话文件，需要回到 Agent App 处理。"
            return
        }

        do {
            let response = try interactionResponse(
                interaction: interaction,
                allow: allow,
                answers: answers
            )
            try writeInteractionReply(response, requestID: interaction.id)
            store?.markInteractionResponded(sessionID: sessionID)
            interactionErrors[sessionID] = nil
            islandController?.island.sessionsDidChange()
            islandController?.refreshLayout()
            NSLog(
                "CoderBar replied to %@ interaction %@ with allow=%@",
                interaction.kind.rawValue,
                interaction.id,
                String(allow)
            )
        } catch {
            let message = "回复失败：\(error.localizedDescription)"
            interactionErrors[sessionID] = message
            NSLog("CoderBar %@", message)
        }
    }

    private func interactionResponse(
        interaction: PendingInteraction,
        allow: Bool,
        answers: [String: [String]]
    ) throws -> [String: Any] {
        if interaction.kind == .approval {
            var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if !allow { decision["message"] = "User denied this request in CoderBar." }
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                ],
            ]
        }

        var output: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": allow ? "allow" : "deny",
        ]
        if !allow {
            output["permissionDecisionReason"] = "User requested changes in CoderBar."
            return ["hookSpecificOutput": output]
        }

        var updatedInput = try foundationObject(interaction.originalToolInput ?? [:])
        if interaction.kind == .question {
            var resolved: [String: String] = [:]
            for question in interaction.questions {
                guard let values = answers[question.id], !values.isEmpty else {
                    throw InteractionReplyError.missingAnswer(question.text)
                }
                resolved[question.text] = values.joined(separator: ", ")
            }
            updatedInput["answers"] = resolved
        }
        output["updatedInput"] = updatedInput
        return ["hookSpecificOutput": output]
    }

    private func foundationObject(_ value: [String: AnyValue]) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InteractionReplyError.invalidToolInput
        }
        return object
    }

    private func writeInteractionReply(_ response: [String: Any], requestID: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !requestID.isEmpty,
              requestID.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { throw InteractionReplyError.invalidRequestID }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coderbar/replies", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        try data.write(
            to: directory.appendingPathComponent("\(requestID).json"),
            options: .atomic
        )
    }

    // MARK: - Launch at login

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/dev.coderbar.agent.plist")
    }

    private func applyLaunchAtLogin() {
        if launchAtLogin {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    private func installLaunchAgent() {
        guard let executable = Bundle.main.executableURL else { return }
        let dir = launchAgentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": "dev.coderbar.agent",
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }
        try? data.write(to: launchAgentURL, options: .atomic)
        runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
    }

    private func removeLaunchAgent() {
        runLaunchctl(["bootout", "gui/\(getuid())", launchAgentURL.path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
    }

    var todaySummary: (sessions: Int, cost: Double) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let active = (store?.sessions ?? []).filter { $0.startedAt >= start && !$0.isAuxiliary }
        let cost = active.reduce(0) { $0 + $1.costEstimate }
        return (active.count, cost)
    }
}

private enum InteractionReplyError: LocalizedError {
    case invalidRequestID
    case invalidToolInput
    case missingAnswer(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequestID: return "请求标识不安全"
        case .invalidToolInput: return "原始工具参数无法编码"
        case .missingAnswer(let question): return "问题尚未回答：\(question)"
        }
    }
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    // UNUserNotificationCenter.current() throws 'bundleProxyForCurrentProcess
    // is nil' when the process has no app bundle (e.g. `swift run`). Loading it
    // unconditionally kills the app before the window is created. Degrade with
    // a visible log instead; packaged .app runs get full notifications.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else {
            if !didWarn {
                didWarn = true
                NSLog("coder-bar: no bundle identifier — user notifications disabled (run the .app bundle to enable)")
            }
            return nil
        }
        return UNUserNotificationCenter.current()
    }
    private var didWarn = false

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(_ p: HookPayload) {
        let cat = p.category ?? p.hookEventName ?? ""
        let agent = AgentNames.display(p.source)
        switch cat {
        case "PermissionRequest", "permission_request", "Permission_request":
            let tool = p.toolName ?? "tool"
            let body = p.prompt.map { SessionStore.eventTextShort($0) } ?? "\(p.permissionMode ?? "") request"
            post(title: "\(agent) needs permission · \(tool)", body: body)
        case "AskUserQuestion", "ask_user_question":
            let q = p.question.map { SessionStore.eventTextShort($0) } ?? "Question"
            post(title: "\(agent) is asking you", body: q)
        default:
            break
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center?.add(req)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
