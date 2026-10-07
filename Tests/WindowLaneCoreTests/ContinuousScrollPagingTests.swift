import XCTest
@testable import WindowLaneCore

final class ContinuousScrollPagingTests: XCTestCase {
    func testDistanceCanStopBetweenPagesWithoutRounding() throws {
        var paging = ContinuousScrollPaging()
        let first = try XCTUnwrap(paging.consume(deltaX: -20, deltaY: 0,
            isPrecise: true, phase: .began, timestamp: 1, currentPosition: 0, count: 4))
        XCTAssertEqual(first.kind, .progress)
        XCTAssertTrue(first.began)
        XCTAssertEqual(first.position, 0.25, accuracy: 0.000_001)
        let result = try XCTUnwrap(paging.consume(deltaX: -30, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 1.1, currentPosition: 0, count: 4))
        XCTAssertEqual(result.kind, .committed)
        XCTAssertEqual(result.position, 0.625, accuracy: 0.000_001)
        XCTAssertFalse(paging.isActive)
    }

    func testNextGestureStartsFromPreviouslyCommittedFraction() throws {
        var paging = ContinuousScrollPaging()
        let result = try XCTUnwrap(paging.consume(deltaX: -10, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 1, currentPosition: 0.375, count: 4))
        XCTAssertEqual(result.kind, .committed)
        XCTAssertTrue(result.began)
        XCTAssertEqual(result.position, 0.5, accuracy: 0.000_001)
    }

    func testDirectionReversalRetracesTheSameDistanceSmoothly() throws {
        var paging = ContinuousScrollPaging()
        let forward = try XCTUnwrap(paging.consume(deltaX: -60, deltaY: 0,
            isPrecise: true, phase: .began, timestamp: 1, currentPosition: 1, count: 5))
        XCTAssertEqual(forward.position, 1.75, accuracy: 0.000_001)
        let reverse = try XCTUnwrap(paging.consume(deltaX: 20, deltaY: 0,
            isPrecise: true, phase: .changed, timestamp: 1.1, currentPosition: 1, count: 5))
        XCTAssertFalse(reverse.began)
        XCTAssertEqual(reverse.position, 1.5, accuracy: 0.000_001)
        let back = try XCTUnwrap(paging.consume(deltaX: 40, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 1.2, currentPosition: 1, count: 5))
        XCTAssertEqual(back.position, 1, accuracy: 0.000_001)
    }

    func testOneGestureCanCrossSeveralPages() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -160, deltaY: 0, isPrecise: true,
            phase: .began, timestamp: 1, currentPosition: 0, count: 6)
        let result = try XCTUnwrap(paging.consume(deltaX: -100, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 1.1, currentPosition: 0, count: 6))
        XCTAssertEqual(result.position, 3.25, accuracy: 0.000_001)
    }

    func testEndpointsDoNotWrapAndOutwardInputDoesNotStart() throws {
        var paging = ContinuousScrollPaging()
        XCTAssertNil(paging.consume(deltaX: 80, deltaY: 0, isPrecise: true,
            timestamp: 1, currentPosition: 0, count: 3))
        XCTAssertFalse(paging.isActive)
        let last = try XCTUnwrap(paging.consume(deltaX: -Double.greatestFiniteMagnitude,
            deltaY: 0, isPrecise: false, phase: .ended, timestamp: 1.1,
            currentPosition: 0, count: 3))
        XCTAssertEqual(last.position, 2)
        XCTAssertNil(paging.consume(deltaX: -80, deltaY: 0, isPrecise: true,
            timestamp: 2, currentPosition: 2, count: 3))
    }

    func testWheelIdleCommitsFractionAndDoesNotQueueNewPage() throws {
        var paging = ContinuousScrollPaging()
        let move = try XCTUnwrap(paging.consume(deltaX: -2, deltaY: 0,
            isPrecise: false, timestamp: 1, currentPosition: 1.2, count: 5))
        XCTAssertEqual(move.position, 1.5, accuracy: 0.000_001)
        XCTAssertNil(paging.commitIfIdle(timestamp: 1.1))
        let commit = try XCTUnwrap(paging.commitIfIdle(timestamp: 1.17))
        XCTAssertEqual(commit.kind, .committed)
        XCTAssertEqual(commit.position, 1.5, accuracy: 0.000_001)
        XCTAssertNil(paging.commitIfIdle(timestamp: 1.4))
    }

    func testHeldPhasedGestureDoesNotCommitFromWheelIdleTimer() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -20, deltaY: 0, isPrecise: true,
            phase: .began, timestamp: 1, currentPosition: 0, count: 3)
        XCTAssertNil(paging.commitIfIdle(timestamp: 5))
        let resumed = try XCTUnwrap(paging.consume(deltaX: -20, deltaY: 0,
            isPrecise: true, phase: .changed, timestamp: 5.1, currentPosition: 0, count: 3))
        XCTAssertEqual(resumed.position, 0.5, accuracy: 0.000_001)
        let ended = try XCTUnwrap(paging.consume(deltaX: 0, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 5.2, currentPosition: 0, count: 3))
        XCTAssertEqual(ended.position, 0.5, accuracy: 0.000_001)
    }

    func testMomentumDoesNotAddDistanceOrStartAnotherGesture() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -20, deltaY: 0, isPrecise: true,
            phase: .began, timestamp: 1, currentPosition: 0, count: 3)
        XCTAssertNil(paging.consume(deltaX: -300, deltaY: 0,
            isPrecise: true, isMomentum: true, timestamp: 1.1, currentPosition: 0, count: 3))
        let ended = try XCTUnwrap(paging.consume(deltaX: 0, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 1.2, currentPosition: 0, count: 3))
        XCTAssertEqual(ended.position, 0.25, accuracy: 0.000_001)
        XCTAssertNil(paging.consume(deltaX: -300, deltaY: 0,
            isPrecise: true, isMomentum: true, timestamp: 1.3, currentPosition: 0.25, count: 3))
    }

    func testVerticalAndDiagonalInputDoNotMoveTheBoundary() throws {
        var paging = ContinuousScrollPaging()
        XCTAssertNil(paging.consume(deltaX: -40, deltaY: 40,
            isPrecise: true, phase: .began, timestamp: 1, currentPosition: 0, count: 3))
        _ = paging.consume(deltaX: -20, deltaY: 0, isPrecise: true,
            phase: .changed, timestamp: 1.1, currentPosition: 0, count: 3)
        XCTAssertNil(paging.consume(deltaX: 0, deltaY: -100,
            isPrecise: true, phase: .changed, timestamp: 1.2, currentPosition: 0, count: 3))
        let ended = try XCTUnwrap(paging.consume(deltaX: 0, deltaY: -5,
            isPrecise: true, phase: .ended, timestamp: 1.3, currentPosition: 0, count: 3))
        XCTAssertEqual(ended.position, 0.25, accuracy: 0.000_001)
    }

    func testCancelledGestureReturnsItsOriginalFraction() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -40, deltaY: 0, isPrecise: true,
            phase: .began, timestamp: 1, currentPosition: 1.3, count: 4)
        let cancelled = try XCTUnwrap(paging.consume(deltaX: -100, deltaY: 0,
            isPrecise: true, phase: .cancelled, timestamp: 1.1, currentPosition: 1.3, count: 4))
        XCTAssertEqual(cancelled.kind, .cancelled)
        XCTAssertEqual(cancelled.position, 1.3, accuracy: 0.000_001)
        XCTAssertFalse(paging.isActive)
        XCTAssertNil(paging.position)
    }

    func testDisabledBusyAndChangedOrderCancelWithoutQueuedInput() throws {
        for reason in 0...2 {
            var paging = ContinuousScrollPaging()
            _ = paging.consume(deltaX: -40, deltaY: 0, isPrecise: true,
                phase: .began, timestamp: 1, currentPosition: 1, count: 4)
            let result = try XCTUnwrap(paging.consume(deltaX: -200, deltaY: 0,
                isPrecise: true, phase: .changed, timestamp: 1.1, currentPosition: 1,
                count: reason == 2 ? 3 : 4, enabled: reason != 0, busy: reason == 1))
            XCTAssertEqual(result.kind, .cancelled)
            XCTAssertEqual(result.position, 1)
            XCTAssertNil(paging.commit())
        }
    }

    func testInvalidDeltasAndBackwardTimeClearActiveGesture() throws {
        for invalid in 0...3 {
            var paging = ContinuousScrollPaging()
            _ = paging.consume(deltaX: -20, deltaY: 0, isPrecise: true,
                timestamp: 1, currentPosition: 0.2, count: 3)
            let result = try XCTUnwrap(paging.consume(
                deltaX: invalid == 0 ? .nan : -5,
                deltaY: invalid == 1 ? .infinity : 0, isPrecise: true,
                timestamp: invalid == 2 ? .nan : (invalid == 3 ? 0.9 : 1.1),
                currentPosition: 0.2, count: 3))
            XCTAssertEqual(result.kind, .cancelled)
            XCTAssertEqual(result.position, 0.2, accuracy: 0.000_001)
            XCTAssertFalse(paging.isActive)
        }
    }

    func testSensitivityChangeCancelsInsteadOfJumping() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -20, deltaY: 0, isPrecise: true,
            timestamp: 1, currentPosition: 1, count: 4, threshold: 80)
        let cancelled = try XCTUnwrap(paging.consume(deltaX: -20, deltaY: 0,
            isPrecise: true, timestamp: 1.1, currentPosition: 1, count: 4, threshold: 30))
        XCTAssertEqual(cancelled.kind, .cancelled)
        XCTAssertEqual(cancelled.position, 1)
        let bounded = try XCTUnwrap(paging.consume(deltaX: -15, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 2,
            currentPosition: 1, count: 4, threshold: 1))
        XCTAssertEqual(bounded.position, 1.5, accuracy: 0.000_001)
    }

    func testDelayedIdleCommitsOldWheelMovementBeforeNewInput() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -20, deltaY: 0, isPrecise: true,
            timestamp: 1, currentPosition: 0, count: 4)
        let old = try XCTUnwrap(paging.consume(deltaX: -80, deltaY: 0,
            isPrecise: true, timestamp: 1.3, currentPosition: 0, count: 4))
        XCTAssertEqual(old.kind, .committed)
        XCTAssertEqual(old.position, 0.25, accuracy: 0.000_001)
        let fresh = try XCTUnwrap(paging.consume(deltaX: -40, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 1.4,
            currentPosition: old.position, count: 4))
        XCTAssertEqual(fresh.position, 0.75, accuracy: 0.000_001)
    }

    func testExplicitResetCancelsPendingIdleAndAllowsFreshPosition() throws {
        var paging = ContinuousScrollPaging()
        _ = paging.consume(deltaX: -60, deltaY: 0, isPrecise: true,
            timestamp: 1, currentPosition: 1, count: 4)
        paging.reset()
        XCTAssertNil(paging.commitIfIdle(timestamp: 4))
        let result = try XCTUnwrap(paging.consume(deltaX: 20, deltaY: 0,
            isPrecise: true, phase: .ended, timestamp: 5, currentPosition: 2.5, count: 4))
        XCTAssertEqual(result.position, 2.25, accuracy: 0.000_001)
    }
}
