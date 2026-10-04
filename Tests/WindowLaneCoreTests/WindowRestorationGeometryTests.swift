import XCTest
import CoreGraphics
@testable import WindowLaneCore

final class WindowRestorationGeometryTests: XCTestCase {
    func testPartiallyOffscreenOriginalCanBeSizedBeforeReturningToItsOrigin() throws {
        let target = CGRect(x: -9, y: 67, width: 2558, height: 1390)
        let visible = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let origin = try XCTUnwrap(WindowRestorationGeometry.stagingOrigin(for: target, visibleFrame: visible))
        XCTAssertEqual(origin, CGPoint(x: 0, y: 50))
        XCTAssertTrue(visible.contains(CGRect(origin: origin, size: target.size)))
        XCTAssertEqual(target, CGRect(x: -9, y: 67, width: 2558, height: 1390))
    }

    func testOrdinaryWorkspaceFrameDoesNotNeedStaging() {
        let visible = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        XCTAssertNil(WindowRestorationGeometry.stagingOrigin(
            for: CGRect(x: 225, y: 42, width: 2110, height: 1306), visibleFrame: visible))
        XCTAssertNil(WindowRestorationGeometry.stagingOrigin(for: visible, visibleFrame: visible))
    }

    func testOriginalLargerThanAvailableDisplayIsNotSilentlyResized() {
        XCTAssertNil(WindowRestorationGeometry.stagingOrigin(
            for: CGRect(x: -9, y: 67, width: 2558, height: 1390),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)))
    }

    func testSecondaryDisplayWithNegativeCoordinatesUsesItsOwnBounds() throws {
        let target = CGRect(x: -1950, y: -80, width: 1500, height: 1000)
        let visible = CGRect(x: -1920, y: -200, width: 1920, height: 1200)
        let origin = try XCTUnwrap(WindowRestorationGeometry.stagingOrigin(for: target, visibleFrame: visible))
        XCTAssertEqual(origin, CGPoint(x: -1920, y: -80))
        XCTAssertTrue(visible.contains(CGRect(origin: origin, size: target.size)))
    }
}
