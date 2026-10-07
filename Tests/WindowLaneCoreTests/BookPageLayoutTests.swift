import XCTest
@testable import WindowLaneCore

final class BookPageLayoutTests: XCTestCase {
    func testHalfTurnMakesTwoEqualNonoverlappingInteractiveFrames() {
        let layout = BookPageLayout(visibleFrame: CGRect(x: -2560, y: 100, width: 2560, height: 1400), mainRatio: 0.9, position: 1.5, count: 4)
        XCTAssertTrue(layout.isSplit)
        XCTAssertEqual(layout.frames.count, 2)
        XCTAssertEqual(layout.frames[1]!.width, layout.frames[2]!.width, accuracy: 0.001)
        XCTAssertFalse(layout.frames[1]!.intersects(layout.frames[2]!))
        for frame in layout.frames.values { XCTAssertTrue(layout.bookFrame.contains(frame)) }
    }
    func testPartialTurnPreservesFractionAndProtectsMinimumWidths() {
        let layout = BookPageLayout(visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900), position: 0.08, count: 3)
        XCTAssertEqual(layout.position, 0.08)
        XCTAssertGreaterThanOrEqual(layout.frames[0]!.width, 320)
        XCTAssertGreaterThanOrEqual(layout.frames[1]!.width, 320)
        XCTAssertGreaterThan(layout.frames[0]!.width, layout.frames[1]!.width)
    }
    func testWholePageUsesExistingCentralFrameAndBoundsInvalidInput() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let single = BookPageLayout(visibleFrame: screen, position: 2, count: 3)
        XCTAssertFalse(single.isSplit)
        XCTAssertEqual(single.frames[2], WorkspaceLayout(visibleFrame: screen).mainFrame)
        XCTAssertEqual(BookPageLayout(visibleFrame: screen, position: .infinity, count: 3).position, 0)
        XCTAssertEqual(BookPageLayout(visibleFrame: screen, position: 100, count: 3).position, 2)
        XCTAssertTrue(BookPageLayout(visibleFrame: screen, position: 0, count: 0).frames.isEmpty)
    }
    func testTinyScreenNeverProducesNegativeOrOverlappingFrames() {
        let layout = BookPageLayout(visibleFrame: CGRect(x: 0, y: 0, width: 160, height: 100), position: 0.5, count: 2)
        for frame in layout.frames.values { XCTAssertGreaterThanOrEqual(frame.width, 0); XCTAssertTrue(layout.bookFrame.contains(frame)) }
        XCTAssertFalse(layout.frames[0]!.intersects(layout.frames[1]!))
    }
    func testApplicationMinimumWidthConstrainsBoundaryWithoutChangingFraction() {
        let layout = BookPageLayout(visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900),
                                    position: 0.08, count: 3, minimumWidths: [1: 700])
        XCTAssertTrue(layout.fitsMinimumWidths)
        XCTAssertEqual(layout.position, 0.08)
        XCTAssertEqual(layout.frames[1]!.width, 700, accuracy: 0.001)
        XCTAssertFalse(layout.frames[0]!.intersects(layout.frames[1]!))
        XCTAssertTrue(layout.frames.values.allSatisfy { layout.bookFrame.contains($0) })
    }
    func testTwoApplicationMinimumsThatCannotFitAreExplicitlyRejected() {
        let layout = BookPageLayout(visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900),
                                    position: 0.5, count: 3, minimumWidths: [0: 800, 1: 800])
        XCTAssertFalse(layout.fitsMinimumWidths)
        XCTAssertEqual(layout.position, 0.5)
        XCTAssertTrue(layout.frames.values.allSatisfy { $0.width.isFinite && $0.width >= 0 })
    }
    func testMinimumWidthsFollowAdjacentIndicesAndIgnoreInvalidValues() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = BookPageLayout(visibleFrame: screen, position: 1.92, count: 4,
                                    minimumWidths: [0: 4000, 1: 700, 2: .nan])
        XCTAssertTrue(layout.fitsMinimumWidths)
        XCTAssertEqual(layout.frames[1]!.width, 700, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(layout.frames[2]!.width, 320)
        let whole = BookPageLayout(visibleFrame: screen, position: 1, count: 4,
                                   minimumWidths: [0: 4000])
        XCTAssertTrue(whole.fitsMinimumWidths)
        XCTAssertEqual(whole.frames[1], WorkspaceLayout(visibleFrame: screen).mainFrame)
    }

}
