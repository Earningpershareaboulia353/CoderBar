import SwiftUI
import AppKit
import CoreGraphics
import CoderBarKit

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosts SwiftUI without putting the hosting view into an Auto Layout graph.
///
/// SwiftUI updates its private focus views while a resizable panel is being
/// displayed. Root constraints around `NSHostingView` can make that focus
/// update request another window constraint pass indefinitely. Autoresizing
/// keeps the hosting view attached to the panel without participating in that
/// constraint cycle. The container draws the small opaque top backing itself,
/// so there is no second AppKit view or constraint set to update.
private final class NotchContentView: NSView {
    private let hostingView: NSView
    private let topBackingHeight: CGFloat
    private let topBackingColor: NSColor

    init(
        hostingView: NSView,
        topBackingHeight: CGFloat,
        topBackingColor: NSColor
    ) {
        self.hostingView = hostingView
        self.topBackingHeight = topBackingHeight
        self.topBackingColor = topBackingColor
        super.init(frame: .zero)

        wantsLayer = true
        layer?.needsDisplayOnBoundsChange = true
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let height = min(topBackingHeight, bounds.height)
        guard height > 0 else { return }
        let backingRect = NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        )
        guard dirtyRect.intersects(backingRect) else { return }

        topBackingColor.setFill()
        backingRect.fill()
    }
}

@MainActor
final class NotchPanelController: NSWindowController, ObservableObject {
    let model: AppModel
    let island: NotchViewModel

    private var eventMonitors: [Any] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var resizeTask: Task<Void, Never>?
    private var previousMouseLocation: CGPoint?
    /// The reference panel changes its real window frame continuously. Keeping
    /// the top edge fixed while width and height animate avoids the flash/jump
    /// caused by allocating a full-size transparent canvas first.
    static let expansionDuration: TimeInterval = 0.42
    static let collapseDuration: TimeInterval = 0.34
    /// Keep one point of the window outside the display while it is attached
    /// to the screen edge. AppKit animates origin and size separately; without
    /// this overlap their pixel rounding can expose a one-pixel seam mid-frame.
    static let attachedTopOverlap: CGFloat = 1
    static let topBackingHeight: CGFloat = 4

    var panel: NotchPanel? {
        window as? NotchPanel
    }

    init(model: AppModel) {
        self.model = model
        self.island = NotchViewModel()
        super.init(window: nil)
        island.model = model
        island.controller = self
        restoreDragOffset()
        buildWindow()
        installDisplayObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func shutdown() {
        resizeTask?.cancel()
        resizeTask = nil
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func buildWindow() {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .none

        let rootView = IslandView(island: island)
            .environmentObject(model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []

        // NSHostingView can expose a transparent scanline for one frame while
        // its layer grows. Draw the attached edge in the AppKit container, but
        // keep the hosting view out of Auto Layout. This avoids the focus-view
        // constraint loop that AppKit treats as a fatal exception.
        let container = NotchContentView(
            hostingView: hostingView,
            topBackingHeight: Self.topBackingHeight,
            topBackingColor: NSColor(
                calibratedRed: 0.012,
                green: 0.012,
                blue: 0.014,
                alpha: 1
            )
        )
        panel.contentView = container
        window = panel
    }

    func show() {
        position(expanded: island.isExpanded, animated: false)
        panel?.orderFrontRegardless()
        installEventMonitors()
        logFrame(reason: "shown")
    }

    var windowFrame: NSRect {
        window?.frame ?? .zero
    }

    func screenForPanel() -> NSScreen? {
        switch model.displayTargetID {
        case "main":
            return systemMainScreen()
        case "focus":
            return focusedApplicationScreen() ?? systemMainScreen()
        case let value where value.hasPrefix("screen:"):
            let identifier = String(value.dropFirst("screen:".count))
            if let screen = NSScreen.screens.first(where: {
                AppModel.screenIdentifier($0) == identifier
            }) {
                return screen
            }
            reportGeometryFailure("Configured display is no longer connected: \(identifier)")
            return nil
        default:
            reportGeometryFailure("Unknown display target: \(model.displayTargetID)")
            return nil
        }
    }

    func position(expanded: Bool, animated: Bool) {
        guard let panel, let screen = screenForPanel() else {
            reportGeometryFailure("Cannot position panel because its window or target screen is missing")
            return
        }

        let contentSize = targetSize(expanded: expanded)
        let screenFrame = screen.frame
        let topOffset = max(0, island.dragOffset.height)
        let desiredTop = screenFrame.maxY - topOffset
        let topOverlap = topOffset <= 0.001 ? Self.attachedTopOverlap : 0
        let windowSize = CGSize(
            width: contentSize.width,
            height: contentSize.height + topOverlap
        )

        var origin = CGPoint(
            x: screenFrame.midX - contentSize.width / 2 + island.dragOffset.width,
            y: desiredTop - contentSize.height
        )
        origin.x = min(
            max(origin.x, screenFrame.minX + 4),
            screenFrame.maxX - contentSize.width - 4
        )
        origin.y = max(origin.y, screenFrame.minY + 4)

        let targetFrame = NSRect(origin: origin, size: windowSize)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded
                    ? Self.expansionDuration
                    : Self.collapseDuration
                context.timingFunction = expanded
                    ? CAMediaTimingFunction(controlPoints: 0.20, 0.78, 0.20, 1.00)
                    : CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.78, 0.32)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }

        logFrame(
            reason: "position expanded=\(expanded) animated=\(animated)",
            targetFrame: targetFrame,
            screen: screen
        )
    }

    func setExpanded(_ expanded: Bool) {
        resizeTask?.cancel()
        logFrame(reason: "transition requested expanded=\(expanded)")
        position(expanded: expanded, animated: true)
    }

    func displayTargetDidChange() {
        position(expanded: island.isExpanded, animated: false)
    }

    func refreshLayout(animated: Bool = true) {
        guard island.isExpanded else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.position(expanded: true, animated: animated)
        }
    }

    func applyDragOffset(_ offset: CGSize) {
        island.dragOffset = offset
        position(expanded: island.isExpanded, animated: false)
    }

    func persistDragOffset() {
        UserDefaults.standard.set(
            "\(island.dragOffset.width),\(island.dragOffset.height)",
            forKey: "notchDragOffset"
        )
        logFrame(reason: "drag offset persisted")
    }

    private func targetSize(expanded: Bool) -> CGSize {
        guard expanded else {
            return CGSize(
                width: IslandMetrics.collapsedWidth,
                height: IslandMetrics.collapsedHeight
            )
        }

        let sessions = model.store?.visibleActiveSessions ?? []
        return CGSize(
            width: model.panelWidth,
            height: IslandMetrics.expandedHeight(
                sessions: sessions,
                showTasks: model.showTasks,
                showSubagents: model.showSubagents,
                maxHeight: model.maxPanelHeight
            )
        )
    }

    private func restoreDragOffset() {
        guard let saved = UserDefaults.standard.string(forKey: "notchDragOffset") else {
            return
        }
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            reportGeometryFailure("Invalid notchDragOffset value: \(saved)")
            return
        }
        island.dragOffset = CGSize(width: parts[0], height: max(0, parts[1]))
    }

    /// `NSScreen.main` follows the current key window and can move between
    /// displays. The "main" setting means the hardware main display instead.
    private func systemMainScreen() -> NSScreen? {
        let displayID = CGMainDisplayID()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }) {
            return screen
        }

        reportGeometryFailure("Cannot resolve CGMainDisplayID \(displayID) to NSScreen")
        return nil
    }

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }

        if let globalClick = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleOutsideClick(at: NSEvent.mouseLocation)
            }
        }) {
            eventMonitors.append(globalClick)
        } else {
            reportGeometryFailure("Failed to install global click monitor")
        }

        if let localClick = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleOutsideClick(at: NSEvent.mouseLocation)
            }
            return event
        }) {
            eventMonitors.append(localClick)
        } else {
            reportGeometryFailure("Failed to install local click monitor")
        }

        if let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            let shouldConsume: Bool = MainActor.assumeIsolated {
                self.handlePanelShortcut(event)
            }
            return shouldConsume ? nil : event
        }) {
            eventMonitors.append(localKey)
        } else {
            reportGeometryFailure("Failed to install local keyboard monitor")
        }

        if let globalMove = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMouseMoved()
            }
        }) {
            eventMonitors.append(globalMove)
        } else {
            reportGeometryFailure("Failed to install global mouse monitor")
        }

        if let localMove = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseMoved()
            }
            return event
        }) {
            eventMonitors.append(localMove)
        } else {
            reportGeometryFailure("Failed to install local mouse monitor")
        }
    }

    private func handlePanelShortcut(_ event: NSEvent) -> Bool {
        guard model.panelShortcutsEnabled, island.isExpanded else { return false }
        if panel?.firstResponder is NSTextView { return false }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if let key,
           let optionNumber = Int(key),
           (1...9).contains(optionNumber),
           submitSingleChoice(optionNumber: optionNumber) {
            return true
        }

        switch key {
        case "\u{1b}":
            island.collapse()
            return true
        case "t":
            guard let session = island.frontSession else { return false }
            _ = TerminalActivator.activate(
                session,
                allowCodexDeepLink: model.openAppServerSessionsInCodex
            )
            return true
        case "y", "n":
            guard let session = model.store?.visibleActiveSessions
                    .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
                    .first(where: {
                        guard let interaction = $0.pendingInteraction else { return false }
                        return interaction.canRespond && interaction.kind != .question
                    }),
                  let interaction = session.pendingInteraction
            else { return false }
            model.respond(
                sessionID: session.id,
                interaction: interaction,
                allow: event.charactersIgnoringModifiers?.lowercased() == "y"
            )
            return true
        default:
            return false
        }
    }

    private func submitSingleChoice(optionNumber: Int) -> Bool {
        guard let session = model.store?.visibleActiveSessions
                .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
                .first(where: { session in
                    guard let interaction = session.pendingInteraction,
                          interaction.kind == .question,
                          interaction.canRespond,
                          interaction.questions.count == 1,
                          let question = interaction.questions.first,
                          !question.isMultiSelect
                    else { return false }
                    return question.options.indices.contains(optionNumber - 1)
                }),
              let interaction = session.pendingInteraction,
              let question = interaction.questions.first
        else { return false }

        let option = question.options[optionNumber - 1]
        NSLog(
            "CoderBar Ask shortcut: session=%@ question=%@ option=%@",
            session.id,
            question.id,
            option.label
        )
        model.respond(
            sessionID: session.id,
            interaction: interaction,
            allow: true,
            answers: [question.id: [option.label]]
        )
        return true
    }

    private func installDisplayObservers() {
        let workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.displayTargetID == "focus" else { return }
                self.displayTargetDidChange()
            }
        }
        notificationObservers.append(workspaceObserver)

        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayTargetDidChange()
            }
        }
        notificationObservers.append(screenObserver)
    }

    private func focusedApplicationScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }

        let focusedBounds = windowList.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        }
        .max { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height }

        guard let focusedBounds, let mainScreen = NSScreen.screens.first else { return nil }
        let matches = NSScreen.screens.map { screen in
            (
                screen: screen,
                area: intersectionArea(
                    focusedBounds,
                    quartzFrame(for: screen, mainScreen: mainScreen)
                )
            )
        }
        guard let match = matches.max(by: { $0.area < $1.area }), match.area > 0 else {
            return nil
        }
        return match.screen
    }

    private func quartzFrame(for screen: NSScreen, mainScreen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: mainScreen.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func handleOutsideClick(at screenPoint: CGPoint) {
        guard island.isExpanded, let panel, !panel.frame.contains(screenPoint) else {
            return
        }
        island.collapse()
    }

    private func handleMouseMoved() {
        guard let panel, let screen = panel.screen else { return }
        let mouse = NSEvent.mouseLocation
        let previous = previousMouseLocation
        previousMouseLocation = mouse

        if island.isExpanded {
            if panel.frame.contains(mouse) {
                island.cancelScheduledCollapse()
            } else {
                island.scheduleCollapseAfterMouseLeave()
            }
            return
        }

        let activationZone = NSRect(
            x: panel.frame.midX - IslandMetrics.collapsedWidth / 2,
            y: screen.frame.maxY - 44,
            width: IslandMetrics.collapsedWidth,
            height: 44
        )
        let enteredFromBelow = previous.map {
            $0.y < activationZone.minY
                && mouse.y >= activationZone.minY
                && mouse.y > $0.y
        } ?? false
        if activationZone.contains(mouse), enteredFromBelow {
            if ProcessInfo.processInfo.environment["CODERBAR_DEBUG"] != nil {
                NSLog(
                    "CoderBar hover entered from below: previous=%@ current=%@ zone=%@",
                    NSStringFromPoint(previous ?? .zero),
                    NSStringFromPoint(mouse),
                    NSStringFromRect(activationZone)
                )
            }
            island.zoneEntered()
        } else if activationZone.contains(mouse),
                  let previous,
                  previous.y > activationZone.maxY,
                  mouse.y <= activationZone.maxY,
                  ProcessInfo.processInfo.environment["CODERBAR_DEBUG"] != nil {
            NSLog(
                "CoderBar hover ignored from above: previous=%@ current=%@ zone=%@",
                NSStringFromPoint(previous),
                NSStringFromPoint(mouse),
                NSStringFromRect(activationZone)
            )
        } else if !activationZone.contains(mouse) {
            island.pointerEntered(false)
        }
    }

    private func reportGeometryFailure(_ message: String) {
        NSLog("CoderBar panel error: %@", message)
    }

    private func logFrame(
        reason: String,
        targetFrame: NSRect? = nil,
        screen: NSScreen? = nil
    ) {
        guard ProcessInfo.processInfo.environment["CODERBAR_DEBUG"] != nil else {
            return
        }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coderbar", isDirectory: true)
        let fileURL = directory.appendingPathComponent("frame.log")
        let selectedScreen = screen ?? panel?.screen
        let actualTopGap = selectedScreen.map {
            $0.frame.maxY - (panel?.frame.maxY ?? $0.frame.maxY)
        } ?? 0
        let targetTopGap = selectedScreen.map {
            $0.frame.maxY - (targetFrame?.maxY ?? $0.frame.maxY)
        } ?? 0
        let message = [
            "\(Date()) \(reason)",
            "actual=\(panel?.frame ?? .zero)",
            "target=\(targetFrame ?? .zero)",
            "screen=\(selectedScreen?.frame ?? .zero)",
            "visible=\(selectedScreen?.visibleFrame ?? .zero)",
            "screenName=\(selectedScreen?.localizedName ?? "missing")",
            "screenID=\(selectedScreen.map(AppModel.screenIdentifier) ?? "missing")",
            "mainDisplayID=\(CGMainDisplayID())",
            "actualTopGap=\(actualTopGap)",
            "targetTopGap=\(targetTopGap)",
            "sessions=\(model.store?.visibleActiveSessions.count ?? 0)"
        ].joined(separator: " ") + "\n"

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(message.utf8))
            try handle.close()
        } catch {
            NSLog("CoderBar frame log failed: %@", String(describing: error))
        }
    }
}
