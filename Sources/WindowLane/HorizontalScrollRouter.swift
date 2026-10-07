import AppKit
import Combine
import WindowLaneCore

/// Local and external events share continuous and discrete gesture state.
/// Global monitors observe only; they never suppress an application's content scroll.
@MainActor final class HorizontalScrollRouter {
    private weak var store: WorkspaceStore?
    private weak var panels: WorkspacePanels?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var gate = HorizontalScrollGate()
    private var paging = ContinuousScrollPaging()
    private var idleTask: Task<Void, Never>?
    private var preferences = Set<AnyCancellable>()
    private var gestureWindowID: String?
    private var gestureApplicationPID: pid_t?

    init(store: WorkspaceStore, panels: WorkspacePanels) {
        self.store = store; self.panels = panels
        store.interaction.$scrollMode.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetGesture()
        }.store(in: &preferences)
        store.interaction.$horizontalSwitchingEnabled.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetGesture()
        }.store(in: &preferences)
        store.interaction.$scrollScope.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetGesture()
        }.store(in: &preferences)
        store.interaction.$scrollThreshold.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetGesture()
        }.store(in: &preferences)
    }

    func updateMonitoring() {
        guard store?.isRunning == true else { stopMonitoring(); return }
        guard localMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:events) { [weak self] event in
            guard event.type == .scrollWheel else {
                MainActor.assumeIsolated { self?.cancelGestureForMouseDown() }
                return event
            }
            let ownsScroll = MainActor.assumeIsolated { self?.handle(event, external:false) ?? false }
            return ownsScroll ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:events) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel { _ = self?.handle(event, external:true) }
                else { self?.cancelGestureForMouseDown() }
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelGestureForApplicationChange() }
        }
    }

    func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        localMonitor = nil; globalMonitor = nil
        activationObserver = nil
        resetGesture()
    }

    @discardableResult private func handle(_ event:NSEvent, external:Bool) -> Bool {
        guard let store, let panels, store.isRunning else { resetGesture(); return false }
        // Do not resize, refocus or consume a scroll while a native drag is held.
        guard NSEvent.pressedMouseButtons == 0 else { resetGesture(); return false }
        let phase = phase(of: event)
        let terminal = phase == .ended || phase == .cancelled
        if !paging.isActive && !store.isBusy { store.trackVisibleFocus() }
        let point = event.window.map { $0.convertPoint(toScreen:event.locationInWindow) } ?? event.locationInWindow
        let isRail = !external && event.window === panels.rail && panels.rail.frame.contains(point)
        let ownedPreview = !external && (event.window === panels.left || event.window === panels.right)
        let activeNative = !external && event.window === store.active?.native
            && event.window?.attachedSheet == nil
        let candidate = store.active?.candidate
        let sameExternalApp = external && candidate?.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Check exact AX focus when opening a gesture and again in apply() when
        // committing it. During progress only the same candidate can continue,
        // avoiding repeated AX round trips on every fractional wheel delta.
        let activeExternal = sameExternalApp && (!paging.isActive
            ? candidate.map { store.backend.isFocused($0) } == true
            : gestureWindowID == store.active?.id)
        let activeFrame = store.active.map { store.frameForWindow($0.id) } ?? store.layout.mainFrame
        let nativeOrExternalArea = paging.isActive ? store.bookLayout.bookFrame : activeFrame
        let insideWorkspace = isRail || (ownedPreview && store.screen.visibleFrame.contains(point))
            || ((activeNative || activeExternal) && nativeOrExternalArea.contains(point))
        let insideScope = store.interaction.scrollScope == .rail ? isRail : insideWorkspace
        let terminalForGesture = terminal && paging.isActive
            && (isRail || ownedPreview || activeNative || activeExternal)
        let enabled = store.interaction.horizontalSwitchingEnabled && (insideScope || terminalForGesture)
        if store.interaction.scrollMode == .continuous {
            let update = paging.consume(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
                isPrecise: event.hasPreciseScrollingDeltas, phase: phase,
                isMomentum: !event.momentumPhase.isEmpty, timestamp: event.timestamp,
                currentPosition: store.pagePosition, count: store.ordered.count,
                enabled: enabled, busy: store.isBusy && !store.isContinuousTurning,
                threshold: store.interaction.scrollThreshold)
            if let update { apply(update, event: event) }
        } else {
            routeStep(event, external: external, phase: phase, enabled: enabled)
        }
        // Dedicated rail/preview surfaces own horizontal local scroll. The two
        // real native panes and every external application retain their events.
        return enabled && (isRail || ownedPreview)
            && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * HorizontalScrollGate.axisDominanceRatio
    }

    private func routeStep(_ event: NSEvent, external: Bool,
                           phase: HorizontalScrollGate.Phase, enabled: Bool) {
        guard let store else { return }
        if let step = gate.consume(deltaX:Double(event.scrollingDeltaX),deltaY:Double(event.scrollingDeltaY),
                                   isPrecise:event.hasPreciseScrollingDeltas,phase:phase,
                                   isMomentum:!event.momentumPhase.isEmpty,timestamp:event.timestamp,
                                   enabled:enabled,busy:store.isBusy,threshold:store.interaction.scrollThreshold) {
            if external {
                guard let candidate = store.active?.candidate, store.backend.isFocused(candidate) else {
                    gate.reset(); return
                }
            }
            store.step(step)
        }
    }

    private func apply(_ update: ContinuousScrollPaging.Update, event: NSEvent? = nil) {
        guard let store else { resetGesture(); return }
        if update.began {
            gestureWindowID = store.active?.id
            gestureApplicationPID = store.active?.candidate?.pid
                ?? store.active?.native.map { _ in ProcessInfo.processInfo.processIdentifier }
            store.beginContinuousPaging()
            guard store.isContinuousTurning else {
                paging.reset(); gestureWindowID = nil; gestureApplicationPID = nil
                return
            }
        }
        switch update.kind {
        case .progress:
            guard store.isContinuousTurning else { resetGesture(); return }
            store.updateContinuousPaging(position: update.position)
            idleTask?.cancel()
            if let event, phase(of: event) == .none { scheduleIdleCommit() }
        case .committed:
            guard NSEvent.pressedMouseButtons == 0, gestureFocusIsValid() else {
                resetGesture(); return
            }
            idleTask?.cancel(); idleTask = nil
            gestureWindowID = nil
            gestureApplicationPID = nil
            store.commitContinuousPaging(position: update.position)
        case .cancelled:
            resetGesture()
        }
    }

    private func scheduleIdleCommit() {
        let interval = paging.idleInterval
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
            guard let self, !Task.isCancelled, let store = self.store, store.isRunning else { return }
            guard NSEvent.pressedMouseButtons == 0 else {
                self.resetGesture(); return
            }
            if let update = self.paging.commitIfIdle(timestamp: ProcessInfo.processInfo.systemUptime) {
                self.apply(update)
            }
        }
    }

    private func gestureFocusIsValid() -> Bool {
        guard let store, let id = gestureWindowID,
              let entry = store.ordered.first(where: { $0.id == id }) else { return false }
        if let native = entry.native { return native.isKeyWindow && native.attachedSheet == nil }
        if let candidate = entry.candidate { return store.backend.isFocused(candidate) }
        return false
    }

    private func resetGesture() {
        idleTask?.cancel(); idleTask = nil
        gate.reset(); paging.reset(); gestureWindowID = nil; gestureApplicationPID = nil
        store?.cancelContinuousPaging()
    }

    private func cancelGestureForMouseDown() {
        guard paging.isActive else { return }
        // The images represent pending geometry. Reveal the unchanged native
        // windows as soon as a click/drag begins, preserving the original event.
        // A global monitor observes only and cannot delay another app's input.
        resetGesture()
    }

    private func cancelGestureForApplicationChange() {
        guard paging.isActive, let expectedPID = gestureApplicationPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPID else { return }
        resetGesture()
    }

    private func phase(of event: NSEvent) -> HorizontalScrollGate.Phase {
        if event.phase.contains(.cancelled) { return .cancelled }
        if event.phase.contains(.ended) { return .ended }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) || event.phase.contains(.mayBegin) || event.phase.contains(.stationary) { return .changed }
        return .none
    }
}
