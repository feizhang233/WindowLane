import Foundation

/// Converts horizontal scroll input into deliberate, discrete workspace steps.
/// The caller supplies monotonic event timestamps and filters events by workspace scope.
public struct HorizontalScrollGate {
    public enum Phase: Sendable {
        case none, began, changed, ended, cancelled
    }

    public static let defaultThreshold = 80.0
    public static let thresholdRange: ClosedRange<Double> = 30...180
    public static let nonPreciseMultiplier = 12.0
    public static let axisDominanceRatio = 1.25

    public let cooldown: TimeInterval
    public let idleResetInterval: TimeInterval

    private var accumulatedX = 0.0
    private var lastEventTime: TimeInterval?
    private var lastTriggerTime: TimeInterval?
    private var lastThreshold: Double?
    private var phaseGestureActive = false
    private var phaseGestureConsumed = false

    public init(cooldown: TimeInterval = 0.45, idleResetInterval: TimeInterval = 0.25) {
        self.cooldown = cooldown.isFinite ? max(0, cooldown) : 0.45
        self.idleResetInterval = idleResetInterval.isFinite ? max(0, idleResetInterval) : 0.25
    }

    public static func boundedThreshold(_ value: Double) -> Double {
        value.isFinite ? min(thresholdRange.upperBound, max(thresholdRange.lowerBound, value)) : defaultThreshold
    }

    /// Clears all pending input and timing state when a workspace or event monitor ends.
    public mutating func reset() {
        accumulatedX = 0
        lastEventTime = nil
        lastTriggerTime = nil
        lastThreshold = nil
        phaseGestureActive = false
        phaseGestureConsumed = false
    }

    /// Returns +1 for next (negative deltaX) or -1 for previous (positive deltaX).
    /// Non-precise wheel ticks are scaled to the same units as trackpad deltas.
    /// Disabled, busy, vertical, momentum, and cooldown input is discarded, never queued.
    public mutating func consume(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        phase: Phase = .none,
        isMomentum: Bool = false,
        timestamp: TimeInterval,
        enabled: Bool = true,
        busy: Bool = false,
        threshold: Double = Self.defaultThreshold
    ) -> Int? {
        guard timestamp.isFinite else {
            accumulatedX = 0
            if phaseGestureActive { phaseGestureConsumed = true }
            return nil
        }
        if let lastEventTime, timestamp < lastEventTime {
            reset()
            self.lastEventTime = timestamp
            return nil
        }
        if let lastEventTime, timestamp - lastEventTime > idleResetInterval {
            accumulatedX = 0
        }
        lastEventTime = timestamp

        let currentThreshold = Self.boundedThreshold(threshold)
        if lastThreshold != currentThreshold { accumulatedX = 0 }
        lastThreshold = currentThreshold

        switch phase {
        case .began:
            accumulatedX = 0
            phaseGestureActive = true
            phaseGestureConsumed = false
        case .changed:
            if !phaseGestureActive {
                accumulatedX = 0
                phaseGestureActive = true
                phaseGestureConsumed = false
            }
        case .ended, .cancelled:
            accumulatedX = 0
            phaseGestureActive = false
            phaseGestureConsumed = false
            return nil
        case .none:
            // A mouse wheel has no phase. Switching devices must not inherit a
            // trackpad latch if its terminal event was lost when focus changed.
            if !isMomentum, phaseGestureActive {
                accumulatedX = 0
                phaseGestureActive = false
                phaseGestureConsumed = false
            }
        }

        guard enabled, !busy else {
            accumulatedX = 0
            if phaseGestureActive { phaseGestureConsumed = true }
            return nil
        }
        guard !isMomentum, deltaX.isFinite, deltaY.isFinite else {
            accumulatedX = 0
            return nil
        }
        guard !phaseGestureConsumed else { return nil }
        if let lastTriggerTime, timestamp - lastTriggerTime < cooldown {
            accumulatedX = 0
            if phaseGestureActive { phaseGestureConsumed = true }
            return nil
        }
        guard abs(deltaX) > abs(deltaY) * Self.axisDominanceRatio, deltaX != 0 else {
            accumulatedX = 0
            return nil
        }

        let normalizedX = deltaX * (isPrecise ? 1 : Self.nonPreciseMultiplier)
        // A reversal starts a new intent instead of cancelling or inheriting old distance.
        if (accumulatedX > 0 && normalizedX < 0) || (accumulatedX < 0 && normalizedX > 0) {
            accumulatedX = 0
        }
        // Saturating at the threshold prevents extreme finite inputs from overflowing.
        accumulatedX = min(currentThreshold, max(-currentThreshold, accumulatedX + normalizedX))
        guard abs(accumulatedX) >= currentThreshold else { return nil }
        let step = accumulatedX < 0 ? 1 : -1
        accumulatedX = 0
        lastTriggerTime = timestamp
        if phaseGestureActive { phaseGestureConsumed = true }
        return step
    }
}
