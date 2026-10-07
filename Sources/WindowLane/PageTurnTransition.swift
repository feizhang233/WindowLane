import AppKit
import QuartzCore

/// A short visual handoff above the real, already-focused destination window.
/// The caller supplies a fresh outgoing image; this object never captures or
/// moves application windows and never takes their keyboard focus.
@MainActor final class PageTurnTransition {
    static let duration: TimeInterval = 0.28

    var isVisible: Bool { panel?.isVisible == true }
    private(set) var isAnimating = false
    private(set) var preparedCount = 0
    private(set) var completedCount = 0
    private(set) var cancelledCount = 0
    private(set) var lastDirection: Int?

    private let reduceMotion: () -> Bool
    private var panel: PageTurnPanel?
    private var pageLayer: CALayer?
    private var generation: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.reduceMotion = reduceMotion
    }

    @discardableResult
    func prepare(image: NSImage, frame: CGRect, direction: Int) -> Bool {
        cancel()
        guard !reduceMotion(), direction != 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 1, frame.height > 1,
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 1, image.size.height > 1,
              abs(image.size.width - frame.width) <= 4,
              abs(image.size.height - frame.height) <= 4,
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              bitmap.width > 0, bitmap.height > 0 else { return false }

        let sign = direction > 0 ? 1 : -1
        let bounds = CGRect(origin: .zero, size: frame.size)
        let root = CALayer()
        root.frame = bounds
        root.masksToBounds = true
        root.backgroundColor = NSColor.clear.cgColor

        let page = CALayer()
        page.frame = bounds
        page.contents = bitmap
        page.contentsGravity = .resize
        page.contentsScale = CGFloat(bitmap.width) / image.size.width
        page.magnificationFilter = .linear
        page.minificationFilter = .linear
        page.isDoubleSided = false

        // A small shadow follows the exposed paper edge. It is clipped by the
        // root, so no decoration spills over the rail, previews or other apps.
        let edge = CAGradientLayer()
        let shadowWidth: CGFloat = 28
        edge.frame = CGRect(x: sign > 0 ? bounds.width - 1 : -shadowWidth + 1,
                            y: 0, width: shadowWidth, height: bounds.height)
        edge.colors = [NSColor.black.withAlphaComponent(0.18).cgColor,
                       NSColor.clear.cgColor]
        edge.startPoint = CGPoint(x: sign > 0 ? 0 : 1, y: 0.5)
        edge.endPoint = CGPoint(x: sign > 0 ? 1 : 0, y: 0.5)
        page.addSublayer(edge)
        root.addSublayer(page)

        let view = PageTurnSurface(frame: bounds)
        view.wantsLayer = true
        view.layer = root

        let overlay = PageTurnPanel(contentRect: frame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        overlay.title = "WindowLane 翻頁過渡"
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        overlay.animationBehavior = .none
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.ignoresMouseEvents = false
        overlay.isReleasedWhenClosed = false
        overlay.isMovable = false
        overlay.becomesKeyOnlyIfNeeded = true
        overlay.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        overlay.contentView = view
        panel = overlay
        pageLayer = page
        lastDirection = sign
        preparedCount += 1
        overlay.orderFrontRegardless()
        return true
    }

    /// Called only after the destination owns native focus. Pointer events are
    /// absorbed during the visual handoff; keyboard events stay with that app.
    func finish() async {
        let token = generation
        guard panel != nil else { return }
        guard !reduceMotion(), !Task.isCancelled else {
            cancel(generation: token)
            return
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard generation == token, panel != nil, !Task.isCancelled else {
                    continuation.resume()
                    cancel(generation: token)
                    return
                }
                waiters.append(continuation)
                guard !isAnimating else { return }
                animate(generation: token)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(generation: token)
            }
        }
    }

    /// Synchronous teardown also releases a suspended finish(), including Stop
    /// while an animation is still in flight. Old completions cannot tear down
    /// a new transition because every lifecycle change invalidates its token.
    func cancel() {
        let wasPrepared = panel != nil
        generation &+= 1
        if wasPrepared { cancelledCount += 1 }
        tearDown()
    }

    private func cancel(generation token: UInt64) {
        guard generation == token else { return }
        cancel()
    }

    private func animate(generation token: UInt64) {
        guard let page = pageLayer, let direction = lastDirection else {
            cancel(generation: token)
            return
        }
        isAnimating = true
        let width = page.bounds.width
        let sign = CGFloat(direction)

        func pose(offset: CGFloat, degrees: CGFloat) -> CATransform3D {
            var transform = CATransform3DIdentity
            transform.m34 = -1 / max(1800, width * 2.5)
            transform = CATransform3DTranslate(transform, -sign * offset * width, 0, 0)
            return CATransform3DRotate(transform, -sign * degrees * .pi / 180, 0, 1, 0)
        }

        let end = pose(offset: 1.08, degrees: 3)
        let turn = CAKeyframeAnimation(keyPath: "transform")
        turn.values = [NSValue(caTransform3D: CATransform3DIdentity),
                       NSValue(caTransform3D: pose(offset: 0.50, degrees: 6)),
                       NSValue(caTransform3D: end)]
        turn.keyTimes = [0, 0.5, 1]
        turn.duration = Self.duration
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.22, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                self?.complete(generation: token)
            }
        }
        page.transform = end
        page.add(turn, forKey: "windowlane.pageTurn")
        CATransaction.commit()
    }

    private func complete(generation token: UInt64) {
        guard generation == token, isAnimating, panel != nil else { return }
        completedCount += 1
        generation &+= 1
        tearDown()
    }

    private func tearDown() {
        // Clear ownership before removing animations, whose completion blocks
        // may already be queued. Neither a bitmap nor a panel survives Stop.
        let oldPanel = panel
        let oldPage = pageLayer
        let pending = waiters
        panel = nil
        pageLayer = nil
        waiters.removeAll()
        isAnimating = false
        oldPanel?.orderOut(nil)
        oldPage?.removeAllAnimations()
        oldPage?.contents = nil
        oldPage?.removeFromSuperlayer()
        oldPanel?.contentView?.layer = nil
        oldPanel?.contentView = nil
        oldPanel?.close()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor private final class PageTurnPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func accessibilityIsIgnored() -> Bool { true }
}

@MainActor private final class PageTurnSurface: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityIsIgnored() -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
}
