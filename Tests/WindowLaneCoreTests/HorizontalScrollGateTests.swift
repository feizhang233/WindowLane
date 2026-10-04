import XCTest
@testable import WindowLaneCore

final class HorizontalScrollGateTests: XCTestCase {
    func testThresholdIsInclusiveAndSmallTouchesDoNotSwitch() {
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: -35, deltaY: 0, isPrecise: true, timestamp: 1))
        XCTAssertNil(gate.consume(deltaX: -44, deltaY: 0, isPrecise: true, timestamp: 1.05))
        XCTAssertEqual(gate.consume(deltaX: -1, deltaY: 0, isPrecise: true, timestamp: 1.1), 1)
    }

    func testWheelTicksNormalizeAndBothDirectionsWork() {
        var gate = HorizontalScrollGate()
        for index in 0..<6 {
            XCTAssertNil(gate.consume(deltaX: 1, deltaY: 0, isPrecise: false, timestamp: Double(index) * 0.02))
        }
        XCTAssertEqual(gate.consume(deltaX: 1, deltaY: 0, isPrecise: false, timestamp: 0.12), -1)
        XCTAssertEqual(gate.consume(deltaX: -7, deltaY: 0, isPrecise: false, timestamp: 0.6), 1)
    }

    func testVerticalAndDiagonalInputClearsPreviousHorizontalIntent() {
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: 70, deltaY: 0, isPrecise: true, timestamp: 0))
        XCTAssertNil(gate.consume(deltaX: 50, deltaY: 60, isPrecise: true, timestamp: 0.05))
        XCTAssertNil(gate.consume(deltaX: 20, deltaY: 0, isPrecise: true, timestamp: 0.1))
        XCTAssertNil(gate.consume(deltaX: 60, deltaY: 50, isPrecise: true, timestamp: 0.15))
        XCTAssertNil(gate.consume(deltaX: 70, deltaY: 0, isPrecise: true, timestamp: 0.2))
        XCTAssertEqual(gate.consume(deltaX: 10, deltaY: 0, isPrecise: true, timestamp: 0.25), -1)
    }

    func testReversalUsesOnlyNewDirectionDistance() {
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, timestamp: 0))
        XCTAssertNil(gate.consume(deltaX: 50, deltaY: 0, isPrecise: true, timestamp: 0.05))
        XCTAssertEqual(gate.consume(deltaX: 30, deltaY: 0, isPrecise: true, timestamp: 0.1), -1)
    }

    func testIdleGapDropsPartialWheelMovement() {
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: -60, deltaY: 0, isPrecise: true, timestamp: 0))
        XCTAssertNil(gate.consume(deltaX: -30, deltaY: 0, isPrecise: true, timestamp: 0.251))
        XCTAssertEqual(gate.consume(deltaX: -50, deltaY: 0, isPrecise: true, timestamp: 0.3), 1)
    }

    func testOnePhaseGestureCannotSwitchTwiceEvenAfterCooldownOrIdle() {
        var gate = HorizontalScrollGate()
        XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0), 1)
        XCTAssertNil(gate.consume(deltaX: -160, deltaY: 0, isPrecise: true, phase: .changed, timestamp: 1))
        XCTAssertNil(gate.consume(deltaX: -160, deltaY: 0, isPrecise: true, phase: .ended, timestamp: 1.1))
        XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 1.2), 1)
    }

    func testCooldownDiscardsWheelDistanceInsteadOfQueuingIt() {
        var gate = HorizontalScrollGate()
        XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, timestamp: 0), 1)
        XCTAssertNil(gate.consume(deltaX: -79, deltaY: 0, isPrecise: true, timestamp: 0.3))
        XCTAssertNil(gate.consume(deltaX: -2, deltaY: 0, isPrecise: true, timestamp: 0.46))
        XCTAssertEqual(gate.consume(deltaX: -78, deltaY: 0, isPrecise: true, timestamp: 0.5), 1)
    }

    func testGestureThatStartsDuringCooldownCannotTriggerFromItsTail() {
        var gate = HorizontalScrollGate()
        XCTAssertEqual(gate.consume(deltaX: 80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0), -1)
        XCTAssertNil(gate.consume(deltaX: 0, deltaY: 0, isPrecise: true, phase: .ended, timestamp: 0.05))
        XCTAssertNil(gate.consume(deltaX: -100, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0.2))
        XCTAssertNil(gate.consume(deltaX: -100, deltaY: 0, isPrecise: true, phase: .changed, timestamp: 0.7))
        XCTAssertNil(gate.consume(deltaX: 0, deltaY: 0, isPrecise: true, phase: .ended, timestamp: 0.8))
        XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0.9), 1)
    }

    func testDisabledAndBusyInputNeitherAccumulatesNorQueuesGestureTail() {
        for disabled in [true, false] {
            var gate = HorizontalScrollGate()
            XCTAssertNil(gate.consume(deltaX: -60, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0))
            XCTAssertNil(gate.consume(deltaX: -120, deltaY: 0, isPrecise: true, phase: .changed, timestamp: 0.1, enabled: !disabled, busy: !disabled))
            XCTAssertNil(gate.consume(deltaX: -120, deltaY: 0, isPrecise: true, phase: .changed, timestamp: 0.6))
            XCTAssertNil(gate.consume(deltaX: 0, deltaY: 0, isPrecise: true, phase: .ended, timestamp: 0.7))
            XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0.8), 1)
        }
        var wheel = HorizontalScrollGate()
        XCTAssertNil(wheel.consume(deltaX: -70, deltaY: 0, isPrecise: true, timestamp: 0))
        XCTAssertNil(wheel.consume(deltaX: -100, deltaY: 0, isPrecise: true, timestamp: 0.1, busy: true))
        XCTAssertNil(wheel.consume(deltaX: -20, deltaY: 0, isPrecise: true, timestamp: 0.2))
    }

    func testMomentumAndCancelledMovementNeverTrigger() {
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0))
        XCTAssertNil(gate.consume(deltaX: -150, deltaY: 0, isPrecise: true, phase: .changed, isMomentum: true, timestamp: 0.05))
        XCTAssertNil(gate.consume(deltaX: -20, deltaY: 0, isPrecise: true, phase: .changed, timestamp: 0.1))
        XCTAssertNil(gate.consume(deltaX: -150, deltaY: 0, isPrecise: true, phase: .cancelled, timestamp: 0.15))
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0.2))
        XCTAssertEqual(gate.consume(deltaX: -10, deltaY: 0, isPrecise: true, phase: .changed, timestamp: 0.25), 1)
    }

    func testInvalidInputAndBackwardsTimeDropAccumulatedMovement() {
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, timestamp: 1))
        XCTAssertNil(gate.consume(deltaX: .nan, deltaY: 0, isPrecise: true, timestamp: 1.05))
        XCTAssertNil(gate.consume(deltaX: -20, deltaY: 0, isPrecise: true, timestamp: 1.1))
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, timestamp: 0.5))
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, timestamp: .infinity))
        XCTAssertNil(gate.consume(deltaX: -70, deltaY: 0, isPrecise: true, timestamp: 0.6))
        XCTAssertEqual(gate.consume(deltaX: -10, deltaY: 0, isPrecise: true, timestamp: 0.65), 1)
    }

    func testThresholdBoundsAndChangesStartFresh() {
        XCTAssertEqual(HorizontalScrollGate.boundedThreshold(10), 30)
        XCTAssertEqual(HorizontalScrollGate.boundedThreshold(500), 180)
        XCTAssertEqual(HorizontalScrollGate.boundedThreshold(.infinity), 80)
        XCTAssertEqual(HorizontalScrollGate.boundedThreshold(.nan), 80)
        var gate = HorizontalScrollGate()
        XCTAssertNil(gate.consume(deltaX: 75, deltaY: 0, isPrecise: true, timestamp: 0, threshold: 180))
        XCTAssertNil(gate.consume(deltaX: 20, deltaY: 0, isPrecise: true, timestamp: 0.05, threshold: 30))
        XCTAssertEqual(gate.consume(deltaX: 10, deltaY: 0, isPrecise: true, timestamp: 0.1, threshold: 30), -1)
    }

    func testResetClearsCooldownAndGestureLatch() {
        var gate = HorizontalScrollGate()
        XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0), 1)
        gate.reset()
        XCTAssertEqual(gate.consume(deltaX: 80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0.1), -1)
    }

    func testExtremeFiniteDeltaSafelySaturatesAtThreshold() {
        var gate = HorizontalScrollGate()
        XCTAssertEqual(gate.consume(deltaX: -Double.greatestFiniteMagnitude, deltaY: 0, isPrecise: false, timestamp: 0), 1)
    }

    func testWheelCanFollowTrackpadWhenItsTerminalPhaseWasLost() {
        var gate = HorizontalScrollGate()
        XCTAssertEqual(gate.consume(deltaX: -80, deltaY: 0, isPrecise: true, phase: .began, timestamp: 0), 1)
        XCTAssertNil(gate.consume(deltaX: -100, deltaY: 0, isPrecise: true, isMomentum: true, timestamp: 0.5))
        XCTAssertEqual(gate.consume(deltaX: 7, deltaY: 0, isPrecise: false, timestamp: 0.6), -1)
    }
}
