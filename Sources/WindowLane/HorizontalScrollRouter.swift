import AppKit
import WindowLaneCore

/// Local and external events share one gate, so a gesture cannot switch twice.
/// Global monitors observe only; they never suppress an application's content scroll.
@MainActor final class HorizontalScrollRouter {
    private weak var store: WorkspaceStore?
    private weak var panels: WorkspacePanels?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var gate = HorizontalScrollGate()

    init(store: WorkspaceStore, panels: WorkspacePanels) {
        self.store = store; self.panels = panels
    }

    func updateMonitoring() {
        guard store?.isRunning == true else { stopMonitoring(); return }
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) { [weak self] event in
            let ownsScroll = MainActor.assumeIsolated { self?.handle(event, external:false) ?? false }
            return ownsScroll ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:.scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event, external:true) }
        }
    }

    func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil; gate.reset()
    }

    @discardableResult private func handle(_ event:NSEvent, external:Bool) -> Bool {
        guard let store, let panels, store.isRunning else { gate.reset(); return false }
        let point = event.window.map { $0.convertPoint(toScreen:event.locationInWindow) } ?? event.locationInWindow
        let isRail = !external && event.window === panels.rail && panels.rail.frame.contains(point)
        let ownedPreview = !external && (event.window === panels.left || event.window === panels.right)
        let activeNative = !external && event.window === store.active?.native
        let activeExternal = external && store.active?.candidate?.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let insideWorkspace = isRail || (ownedPreview && store.screen.visibleFrame.contains(point))
            || ((activeNative || activeExternal) && store.layout.mainFrame.contains(point))
        let insideScope = store.interaction.scrollScope == .rail ? isRail : insideWorkspace
        let enabled = store.interaction.horizontalSwitchingEnabled && insideScope
        let phase:HorizontalScrollGate.Phase
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) || event.phase.contains(.mayBegin) || event.phase.contains(.stationary) { phase = .changed }
        else { phase = .none }
        if let step = gate.consume(deltaX:Double(event.scrollingDeltaX),deltaY:Double(event.scrollingDeltaY),
                                   isPrecise:event.hasPreciseScrollingDeltas,phase:phase,
                                   isMomentum:!event.momentumPhase.isEmpty,timestamp:event.timestamp,
                                   enabled:enabled,busy:store.isBusy,threshold:store.interaction.scrollThreshold) {
            if external {
                guard let candidate = store.active?.candidate, store.backend.isFocused(candidate) else {
                    gate.reset(); return false
                }
            }
            store.step(step)
        }
        // Only the dedicated rail/preview surfaces own and consume local scroll.
        return enabled && (isRail || ownedPreview)
            && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * HorizontalScrollGate.axisDominanceRatio
    }
}
