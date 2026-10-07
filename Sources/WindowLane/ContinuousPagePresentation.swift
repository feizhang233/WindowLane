import AppKit
import QuartzCore

/// A memory-only visual companion to a continuous wheel gesture. Native window
/// geometry is owned by WorkspaceStore, and every pointer event passes through.
/// The caller supplies the same global pane frames that it will commit natively.
@MainActor final class ContinuousPagePresentation {
    static let finishDuration: TimeInterval = 0.14

    var isVisible: Bool { panel?.isVisible == true }
    private(set) var isAnimating = false
    private(set) var position: Double?
    private(set) var preparedCount = 0
    private(set) var completedCount = 0
    private(set) var cancelledCount = 0

    private let reduceMotion: () -> Bool
    private var panel: ContinuousPagePanel?
    private var panes: [Int: Pane] = [:]
    private var bookFrame = CGRect.zero
    private var mainRatio = 0.9
    private var generation: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.reduceMotion = reduceMotion
    }

    @discardableResult
    func prepare(images: [NSImage?], titles: [String], frame: CGRect,
                 position: Double, mainRatio: Double = 0.9,
                 frames: [Int: CGRect]? = nil) -> Bool {
        cancel()
        guard !reduceMotion(), valid(frame), !images.isEmpty, images.count <= 6,
              position.isFinite else { return false }
        self.bookFrame = frame
        self.mainRatio = mainRatio.isFinite ? min(0.95, max(0.5, mainRatio)) : 0.9
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.masksToBounds = true
        root.backgroundColor = NSColor.clear.cgColor
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        for index in images.indices {
            let page = CALayer()
            page.masksToBounds = true
            page.cornerRadius = 8
            page.borderWidth = 0.5
            page.borderColor = NSColor.separatorColor.cgColor
            page.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let content = CALayer()
            content.contentsGravity = .resizeAspectFill
            content.magnificationFilter = .linear
            content.minificationFilter = .linear
            content.contentsScale = scale
            page.addSublayer(content)
            let placeholder = CATextLayer()
            placeholder.contentsScale = scale
            placeholder.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            placeholder.fontSize = 14
            placeholder.alignmentMode = .center
            placeholder.truncationMode = .end
            placeholder.isWrapped = true
            placeholder.foregroundColor = NSColor.secondaryLabelColor.cgColor
            let title = titles.indices.contains(index) && !titles[index].isEmpty
                ? titles[index] : "視窗 \(index + 1)"
            if let image = images[index],
               image.size.width.isFinite, image.size.height.isFinite,
               image.size.width > 1, image.size.height > 1,
               let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               bitmap.width > 0, bitmap.height > 0 {
                content.contents = bitmap
                placeholder.isHidden = true
            } else {
                placeholder.string = "\(title)\n預覽暫時無法顯示"
            }
            page.addSublayer(placeholder)
            root.addSublayer(page)
            panes[index] = Pane(page: page, content: content, placeholder: placeholder)
        }

        let view = ContinuousPageSurface(frame: root.frame)
        view.wantsLayer = true
        view.layer = root
        let overlay = ContinuousPagePanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.title = "WindowLane 連續翻頁"
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        overlay.animationBehavior = .none
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.isMovable = false
        overlay.becomesKeyOnlyIfNeeded = true
        overlay.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        overlay.contentView = view
        panel = overlay
        preparedCount += 1
        update(position: position, frames: frames)
        guard panel === overlay else { return false }
        overlay.orderFrontRegardless()
        return true
    }

    /// Use BookPageLayout.frames here to align previews with the actual panes.
    /// This path has no easing or detents: every valid input distance is visible.
    func update(position: Double, frames: [Int: CGRect]? = nil) {
        guard panel != nil, position.isFinite else { return }
        guard !reduceMotion() else { cancel(); return }
        guard !isAnimating else { return }
        let bounded = min(Double(max(0, panes.count - 1)), max(0, position))
        self.position = bounded
        apply(frames: resolvedFrames(position: bounded, supplied: frames), animated: false)
    }

    /// Call only after real native geometry is ready. Fractions remain fractions;
    /// this method never rounds to a page. cancel() can reveal native panes at once.
    func finish(toPosition position: Double, frames: [Int: CGRect]? = nil) async {
        let token = generation
        guard panel != nil else { return }
        guard position.isFinite else { cancel(generation: token); return }
        guard !reduceMotion(), !Task.isCancelled else {
            cancel(generation: token)
            return
        }
        let bounded = min(Double(max(0, panes.count - 1)), max(0, position))
        let destination = resolvedFrames(position: bounded, supplied: frames)
        self.position = bounded
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard generation == token, panel != nil, !Task.isCancelled else {
                    continuation.resume()
                    cancel(generation: token)
                    return
                }
                waiters.append(continuation)
                guard !isAnimating else { return }
                let moved = destination.contains { index, frame in
                    panes[index]?.page.frame != local(frame)
                }
                guard moved else {
                    complete(generation: token)
                    return
                }
                isAnimating = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                CATransaction.setCompletionBlock { [weak self] in
                    Task { @MainActor in self?.complete(generation: token) }
                }
                apply(frames: destination, animated: true)
                CATransaction.commit()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(generation: token) }
        }
    }

    /// Synchronous cleanup releases an in-flight finish continuation exactly once.
    func cancel() {
        if panel != nil { cancelledCount += 1 }
        generation &+= 1
        tearDown()
    }

    private func cancel(generation token: UInt64) {
        guard generation == token else { return }
        cancel()
    }

    private func complete(generation token: UInt64) {
        guard generation == token, panel != nil else { return }
        completedCount += 1
        generation &+= 1
        tearDown()
    }

    private func resolvedFrames(position: Double, supplied: [Int: CGRect]?) -> [Int: CGRect] {
        if let supplied {
            return supplied.filter { index, frame in
                panes[index] != nil && valid(frame) && frame.intersects(bookFrame)
            }
        }
        let first = Int(floor(position))
        let fraction = position - Double(first)
        if fraction < 0.000_001 || first == panes.count - 1 {
            let width = bookFrame.width * mainRatio
            return [first: CGRect(x: bookFrame.midX - width / 2, y: bookFrame.minY,
                                  width: width, height: bookFrame.height)]
        }
        let gap = min(12, bookFrame.width / 4)
        let width = max(0, bookFrame.width - gap)
        let share = mainRatio - (2 * mainRatio - 1) * fraction
        let leftWidth = width * share
        return [first: CGRect(x: bookFrame.minX, y: bookFrame.minY,
                              width: leftWidth, height: bookFrame.height),
                first + 1: CGRect(x: bookFrame.minX + leftWidth + gap, y: bookFrame.minY,
                                  width: width - leftWidth, height: bookFrame.height)]
    }

    private func apply(frames: [Int: CGRect], animated: Bool) {
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        for (index, pane) in panes {
            guard let global = frames[index] else { pane.page.isHidden = true; continue }
            pane.page.isHidden = false
            let frame = local(global)
            if animated {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(point: pane.page.position)
                move.toValue = NSValue(point: CGPoint(x: frame.midX, y: frame.midY))
                let resize = CABasicAnimation(keyPath: "bounds")
                resize.fromValue = NSValue(rect: pane.page.bounds)
                resize.toValue = NSValue(rect: CGRect(origin: .zero, size: frame.size))
                let group = CAAnimationGroup()
                group.animations = [move, resize]
                group.duration = Self.finishDuration
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pane.page.add(group, forKey: "windowlane.continuousCommit")
            }
            pane.page.frame = frame
            pane.content.frame = CGRect(origin: .zero, size: frame.size)
            pane.placeholder.frame = CGRect(x: 16, y: max(12, frame.height / 2 - 30),
                                             width: max(0, frame.width - 32), height: 60)
        }
        if !animated { CATransaction.commit() }
    }

    private func local(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: -bookFrame.minX, dy: -bookFrame.minY)
    }

    private func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite &&
            frame.height.isFinite && frame.width > 1 && frame.height > 1
    }

    private func tearDown() {
        let oldPanel = panel
        let oldPanes = panes
        let pending = waiters
        panel = nil
        panes.removeAll()
        waiters.removeAll()
        position = nil
        isAnimating = false
        oldPanel?.orderOut(nil)
        for pane in oldPanes.values {
            pane.page.removeAllAnimations()
            pane.content.contents = nil
            pane.placeholder.string = nil
            pane.page.removeFromSuperlayer()
        }
        oldPanel?.contentView?.layer = nil
        oldPanel?.contentView = nil
        oldPanel?.close()
        for waiter in pending { waiter.resume() }
    }

    private struct Pane {
        let page: CALayer
        let content: CALayer
        let placeholder: CATextLayer
    }
}

@MainActor private final class ContinuousPagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func accessibilityIsIgnored() -> Bool { true }
}

@MainActor private final class ContinuousPageSurface: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityIsIgnored() -> Bool { true }
}
