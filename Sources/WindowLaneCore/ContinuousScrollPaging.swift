import Foundation

/// Integrates side-wheel distance into a continuous position in the workspace.
/// A position of 1.4 means the boundary is 40% of the way from page 1 to page 2.
/// Ending a gesture preserves that fraction; the caller commits real geometry.
public struct ContinuousScrollPaging {
    public typealias Phase = HorizontalScrollGate.Phase

    public enum Kind: Sendable, Equatable {
        case progress
        case committed
        case cancelled
    }

    public struct Update: Sendable, Equatable {
        public let kind: Kind
        public let position: Double
        public let began: Bool
    }

    public let idleInterval: TimeInterval
    public private(set) var isActive = false
    public private(set) var position: Double?

    private var origin = 0.0
    private var pageCount = 0
    private var gestureThreshold = HorizontalScrollGate.defaultThreshold
    private var hasPhase = false
    private var lastEventTime: TimeInterval?

    public init(idleInterval: TimeInterval = 0.16) {
        self.idleInterval = idleInterval.isFinite ? max(0.04, idleInterval) : 0.16
    }

    /// Reset when the workspace, order, screen, mode or event monitor changes.
    public mutating func reset() {
        isActive = false
        position = nil
        origin = 0
        pageCount = 0
        hasPhase = false
        lastEventTime = nil
    }

    /// Positive horizontal input moves toward the previous page, negative input
    /// toward the next. Reversing direction subtracts distance without a jump.
    /// Phased endings and mouse-wheel idle both commit the exact fraction.
    public mutating func consume(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        phase: Phase = .none,
        isMomentum: Bool = false,
        timestamp: TimeInterval,
        currentPosition: Double,
        count: Int,
        enabled: Bool = true,
        busy: Bool = false,
        threshold: Double = HorizontalScrollGate.defaultThreshold
    ) -> Update? {
        guard enabled, !busy, count > 1, currentPosition.isFinite,
              timestamp.isFinite, deltaX.isFinite, deltaY.isFinite else {
            return cancel()
        }
        if let lastEventTime, timestamp < lastEventTime {
            return cancel()
        }
        if isActive, count != pageCount {
            return cancel()
        }
        if phase == .cancelled { return cancel() }

        // Momentum is never turned into additional pages. Terminal phase input
        // is processed first so an otherwise empty ended event can still commit.
        if isMomentum {
            return phase == .ended ? commit() : nil
        }
        let boundedThreshold = HorizontalScrollGate.boundedThreshold(threshold)
        if isActive, boundedThreshold != gestureThreshold {
            return cancel()
        }
        if isActive, !hasPhase, let lastEventTime,
           timestamp - lastEventTime >= idleInterval {
            // Normally the caller's idle timer commits first. If it was delayed,
            // finish the old input before accepting a new independent gesture.
            return commit()
        }
        if phase == .began, isActive { reset() }

        let horizontal = deltaX != 0 &&
            abs(deltaX) > abs(deltaY) * HorizontalScrollGate.axisDominanceRatio
        guard horizontal else {
            return phase == .ended ? commit() : nil
        }

        let began = !isActive
        if began {
            origin = min(Double(count - 1), max(0, currentPosition))
            position = origin
            pageCount = count
            gestureThreshold = boundedThreshold
            hasPhase = phase != .none
        }
        let normalized = -deltaX * (isPrecise ? 1 : HorizontalScrollGate.nonPreciseMultiplier)
        let distance = normalized / gestureThreshold
        let oldPosition = position ?? origin
        let proposed = oldPosition + distance
        let newPosition: Double
        if proposed.isFinite {
            newPosition = min(Double(pageCount - 1), max(0, proposed))
        } else {
            newPosition = distance > 0 ? Double(pageCount - 1) : 0
        }
        // Scrolling outward at an endpoint has no visual or layout effect.
        guard !began || newPosition != origin else {
            reset()
            return nil
        }
        isActive = true
        position = newPosition
        lastEventTime = timestamp
        if phase == .ended { return commit(began: began) }
        return Update(kind: .progress, position: newPosition, began: began)
    }

    /// Called by a monotonic idle timer for wheels that do not report phases.
    /// A held trackpad gesture must not be committed by this timer.
    public mutating func commitIfIdle(timestamp: TimeInterval) -> Update? {
        guard isActive, !hasPhase, timestamp.isFinite, let lastEventTime,
              timestamp >= lastEventTime,
              timestamp - lastEventTime >= idleInterval else { return nil }
        return commit()
    }

    public mutating func commit() -> Update? { commit(began: false) }

    /// Cancelling restores the fractional position at the start of the gesture.
    /// It does not select or move a window; those operations belong to the caller.
    public mutating func cancel() -> Update? {
        guard isActive else { reset(); return nil }
        let result = Update(kind: .cancelled, position: origin, began: false)
        reset()
        return result
    }

    private mutating func commit(began: Bool) -> Update? {
        guard isActive, let position else { return nil }
        let result = Update(kind: .committed, position: position, began: began)
        reset()
        return result
    }
}
