import SwiftUI
import CoderBarKit

/// State machine for the notch island: collapsed/expanded, hover-to-expand,
/// auto-collapse on mouse leave, transient alert reveal, session cycling.
/// Mirrors the original's NotchViewModel behaviour.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var isAlertFlashing = false
    @Published var cycleIndex = 0
    @Published var dragOffset: CGSize = .zero
    @Published var completionCard: CompletionCard?

    struct CompletionCard: Equatable {
        var title: String
        var model: String?
        var durationText: String
        var costText: String
    }

    weak var controller: NotchPanelController?

    private var hoverTimer: Timer?
    var collapseTimer: Timer?
    private var alertTimer: Timer?
    private var cooldownUntil: Date = .distantPast
    private var dragStartOffset: CGSize = .zero
    private var isDragging = false

    // MARK: - Hover

    func pointerEntered(_ inside: Bool) {
        if inside {
            guard model?.hoverToExpand != false,
                  !isExpanded,
                  Date() > cooldownUntil
            else { return }
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(
                withTimeInterval: model?.hoverDelaySeconds ?? 0.15,
                repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.expand()
                }
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    // MARK: - Expand / collapse

    func toggle() {
        if isExpanded { collapse() } else { expand() }
    }

    func expand(transient: Bool = false) {
        hoverTimer?.invalidate()
        controller?.setExpanded(true)
        withAnimation(
            .timingCurve(0.20, 0.78, 0.20, 1.00,
                         duration: NotchPanelController.expansionDuration)
        ) {
            isExpanded = true
        }
        cooldownUntil = .distantPast
        if transient {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(
                withTimeInterval: model?.alertDwellSeconds ?? 5,
                repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.collapseIfMouseOutside()
                }
            }
        }
    }

    func collapse() {
        collapseTimer?.invalidate()
        withAnimation(
            .timingCurve(0.40, 0.00, 0.78, 0.32,
                         duration: NotchPanelController.collapseDuration)
        ) {
            isExpanded = false
        }
        controller?.setExpanded(false)
        cooldownUntil = Date().addingTimeInterval(0.35)
    }

    func scheduleCollapseAfterMouseLeave() {
        if ProcessInfo.processInfo.environment["CODERBAR_DEBUG_DISABLE_AUTO_COLLAPSE"] != nil {
            return
        }
        guard model?.autoCollapseOnMouseLeave != false,
              isExpanded,
              collapseTimer == nil
        else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collapseTimer = nil
                self?.collapseIfMouseOutside()
            }
        }
    }

    func cancelScheduledCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    func collapseIfMouseOutside() {
        guard let controller else { return }
        let mouse = NSEvent.mouseLocation
        if !controller.windowFrame.contains(mouse) {
            collapse()
        }
    }

    // MARK: - Session cycling (Option+click or scroll wheel)

    var runningSessions: [SessionStore.Session] {
        model?.store?.visibleActiveSessions ?? []
    }

    weak var model: AppModel?

    init() {
        if ProcessInfo.processInfo.environment["CODERBAR_DEBUG_AUTO_EXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.expand()
            }
        }
        if ProcessInfo.processInfo.environment["CODERBAR_DEBUG_AUTO_COLLAPSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.expand()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.collapse()
                }
            }
        }
    }

    var frontSession: SessionStore.Session? {
        let running = runningSessions.sorted { $0.startedAt > $1.startedAt }
        if running.isEmpty { return nil }
        if cycleIndex < running.count {
            return running[cycleIndex]
        }
        cycleIndex = 0
        return running.first
    }

    func cycle(_ delta: Int = 1) {
        let running = runningSessions
        guard !running.isEmpty else { return }
        cycleIndex = ((cycleIndex + delta) % running.count + running.count) % running.count
    }

    // MARK: - Alert flash

    func onAlert() {
        isAlertFlashing = true
        alertTimer?.invalidate()
        alertTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAlertFlashing = false
            }
        }
    }

    // MARK: - Completion card (original's CompletionCardView)

    func showCompletion(_ session: SessionStore.Session) {
        let end = session.endedAt ?? Date()
        let secs = max(0, end.timeIntervalSince(session.startedAt))
        let dur = secs < 60 ? "\(Int(secs))s"
            : secs < 3600 ? "\(Int(secs / 60))m \(Int(secs.truncatingRemainder(dividingBy: 60)))s"
            : "\(Int(secs / 3600))h"
        completionCard = CompletionCard(
            title: session.displayTitle,
            model: session.model,
            durationText: dur,
            costText: session.costEstimate > 0
                ? String(format: "~$%.3f", session.costEstimate)
                : "no cost data"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            Task { @MainActor in
                if self?.completionCard?.title == session.displayTitle {
                    self?.completionCard = nil
                }
            }
        }
    }

    /// Mouse entered the menu-bar zone above the island (original's
    /// `_isMouseInMenuBarZone`) — treat like a hover.
    func zoneEntered() {
        pointerEntered(true)
    }

    // MARK: - Drag

    func dragBegan() {
        guard !isDragging else { return }
        isDragging = true
        dragStartOffset = dragOffset
    }

    func dragMoved(_ translation: CGSize) {
        let next = CGSize(width: dragStartOffset.width + translation.width,
                          height: dragStartOffset.height + translation.height)
        controller?.applyDragOffset(next)
    }

    func dragEnded() {
        isDragging = false
        controller?.persistDragOffset()
    }

    func sessionsDidChange() {
        objectWillChange.send()
    }

}
