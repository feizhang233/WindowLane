import AppKit
import SwiftUI

/// Spring-loads a neighboring real window while the user's original native
/// drag session stays owned by its source application. This is navigation only:
/// it never reads drag payloads, creates a replacement session or accepts a drop.
@MainActor final class DragTransferRouter {
    let hoverDelay: TimeInterval
    private(set) var isDragging = false
    private(set) var hoverDirection: Int?
    private(set) var navigationCount = 0

    private let isEnabled: () -> Bool
    private let canNavigate: (Int) -> Bool
    private let navigate: (Int) -> Void
    private let onDragStateChanged: (Bool) -> Void
    private var sequenceNumber: Int?
    private var hoverStartedAt: TimeInterval?
    private var openedForThisVisit = false

    init(hoverDelay: TimeInterval = 0.45,
         isEnabled: @escaping () -> Bool,
         canNavigate: @escaping (Int) -> Bool,
         navigate: @escaping (Int) -> Void,
         onDragStateChanged: @escaping (Bool) -> Void = { _ in }) {
        self.hoverDelay = max(0.1, hoverDelay.isFinite ? hoverDelay : 0.45)
        self.isEnabled = isEnabled
        self.canNavigate = canNavigate
        self.navigate = navigate
        self.onDragStateChanged = onDragStateChanged
    }

    /// AppKit sends periodic updates even when a navigation-only destination
    /// returns .none. Measuring those updates avoids a delayed callback after
    /// a drag exits, a workspace stops, or a different drag session begins.
    @discardableResult
    func updateHover(sequence: Int, direction: Int,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard direction == -1 || direction == 1, now.isFinite else { return false }
        guard isEnabled(), canNavigate(direction) else {
            // Navigation makes the store briefly busy. Keep an already-opened
            // visit latched so that becoming ready cannot turn another page
            // under the same stationary pointer.
            if !openedForThisVisit {
                endHover(sequence: sequence, direction: direction)
            }
            return false
        }
        if sequenceNumber != sequence {
            resetHover()
            sequenceNumber = sequence
        }
        setDragging(true)
        if hoverDirection != direction {
            hoverDirection = direction
            hoverStartedAt = now
            openedForThisVisit = false
        }
        guard !openedForThisVisit, let startedAt = hoverStartedAt,
              now >= startedAt, now - startedAt >= hoverDelay else { return true }

        // Mark before notifying the store: a synchronous state update may cause
        // another draggingUpdated while the pointer remains on the same edge.
        openedForThisVisit = true
        navigationCount += 1
        navigate(direction)
        return true
    }

    func endHover(sequence: Int, direction: Int) {
        guard sequenceNumber == sequence, hoverDirection == direction else { return }
        resetHover()
        // The drag is still live as the pointer travels into the real window.
        // draggingEnded or workspace cancellation releases this state.
    }

    func endDrag(sequence: Int) {
        guard sequenceNumber == sequence else { return }
        cancel()
    }

    func cancel() {
        resetHover()
        sequenceNumber = nil
        setDragging(false)
    }

    private func resetHover() {
        hoverDirection = nil
        hoverStartedAt = nil
        openedForThisVisit = false
    }

    private func setDragging(_ active: Bool) {
        guard isDragging != active else { return }
        isDragging = active
        onDragStateChanged(active)
    }
}

/// Hosts the existing SwiftUI preview, preserving its regular buttons and
/// accessibility. A native drag can dwell on the preview to reveal the adjacent
/// window, then move back into that window for the destination app to handle it.
@MainActor final class EdgeDropHostingView<Content: View>: NSHostingView<Content> {
    private let direction: Int
    private let router: DragTransferRouter

    // Inspect only advertised type names. In particular, never resolve a file
    // promise or load a photo merely because the drag passes over this preview.
    static var navigationTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL, .URL, .png, .tiff, .pdf, .string, .rtf, .rtfd,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        return Array(Set(types))
    }

    init(rootView: Content, direction: Int, router: DragTransferRouter) {
        precondition(direction == -1 || direction == 1)
        self.direction = direction
        self.router = router
        super.init(rootView: rootView)
        registerForDraggedTypes(Self.navigationTypes)
    }

    @available(*, unavailable)
    required init(rootView: Content) { fatalError("Use init(rootView:direction:router:)") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:direction:router:)") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateNavigation(sender)
        return []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateNavigation(sender)
        return []
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard let sender else { router.cancel(); return }
        router.endHover(sequence: sender.draggingSequenceNumber, direction: direction)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        router.endDrag(sequence: sender.draggingSequenceNumber)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        router.endDrag(sequence: sender.draggingSequenceNumber)
        return false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        router.endDrag(sequence: sender.draggingSequenceNumber)
        return false
    }

    private func updateNavigation(_ sender: any NSDraggingInfo) {
        guard !sender.draggingSourceOperationMask.isEmpty,
              sender.draggingPasteboard.availableType(from: Self.navigationTypes) != nil else {
            router.endHover(sequence: sender.draggingSequenceNumber, direction: direction)
            return
        }
        router.updateHover(sequence: sender.draggingSequenceNumber, direction: direction)
    }
}
