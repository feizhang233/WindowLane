import XCTest
import CoreGraphics
@testable import WindowLaneCore

final class WorkspaceOrderTests: XCTestCase {
    func testCapacityAndDuplicateAttemptsPreserveExistingWorkspace() throws {
        var order = WorkspaceOrder()
        for number in 1...6 { try order.add("window-\(number)") }
        let fullOrder = order
        XCTAssertThrowsError(try order.add("window-7")) {
            XCTAssertEqual($0 as? WorkspaceOrderError, .workspaceFull)
        }
        XCTAssertThrowsError(try order.add("window-1")) {
            XCTAssertEqual($0 as? WorkspaceOrderError, .alreadyAdded("window-1"))
        }
        XCTAssertEqual(order, fullOrder)
        XCTAssertEqual(order.activeID, "window-1")
    }

    func testReorderKeepsSelectedWindowIdentity() {
        var order = WorkspaceOrder(ids: ["pdf", "notes", "browser"], activeID: "notes")
        order.move(from: 1, to: 2)
        XCTAssertEqual(order.ids, ["pdf", "browser", "notes"])
        XCTAssertEqual(order.activeID, "notes")
        order.move(from: 0, to: 2)
        XCTAssertEqual(order.ids, ["browser", "notes", "pdf"])
        XCTAssertEqual(order.activeID, "notes")
        order.step(1)
        XCTAssertEqual(order.activeID, "pdf")
    }

    func testRemovingActiveWindowSelectsNeighborAndLastRemovalClearsSelection() {
        var order = WorkspaceOrder(ids: ["pdf", "notes", "browser"], activeID: "notes")
        order.remove("notes")
        XCTAssertEqual(order.ids, ["pdf", "browser"])
        XCTAssertEqual(order.activeID, "browser")
        order.remove("browser")
        XCTAssertEqual(order.activeID, "pdf")
        order.remove("pdf")
        XCTAssertNil(order.activeID)
        order.step(1)
        XCTAssertTrue(order.ids.isEmpty)
    }

    func testRemovingOtherWindowPreservesSelection() {
        var order = WorkspaceOrder(ids: ["pdf", "notes", "browser"], activeID: "notes")
        order.remove("pdf")
        XCTAssertEqual(order.activeID, "notes")
    }

    func testNavigationStopsAtBothEndsEvenForExtremeOffsets() {
        var order = WorkspaceOrder(ids: ["a", "b", "c"])
        order.step(-1)
        XCTAssertEqual(order.activeID, "a")
        order.step(1)
        XCTAssertEqual(order.activeID, "b")
        order.step(Int.max)
        XCTAssertEqual(order.activeID, "c")
        order.step(1)
        XCTAssertEqual(order.activeID, "c")
        order.step(Int.min)
        XCTAssertEqual(order.activeID, "a")
    }

    func testInvalidRequestsDoNotAlterSelectionOrOrder() throws {
        var order = WorkspaceOrder(ids: ["a", "b"], activeID: "b")
        let original = order
        order.select("unknown")
        order.remove("unknown")
        order.move(from: -1, to: 1)
        order.move(from: 1, to: 2)
        XCTAssertThrowsError(try order.add(""))
        XCTAssertEqual(order, original)
    }

    func testDecodingNormalizesPersistedInvalidIdentities() throws {
        let data = Data(#"{"ids":["a","a","","b","c","d","e","f","g"],"activeID":"g"}"#.utf8)
        let order = try JSONDecoder().decode(WorkspaceOrder.self, from: data)
        XCTAssertEqual(order.ids, ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(order.activeID, "a")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceOrder.self, from: JSONEncoder().encode(order)), order)
    }
}

final class WorkspaceLayoutTests: XCTestCase {
    func testFramesFitVisibleAreaAndDoNotOverlapAcrossDisplays() {
        let displays: [CGRect] = [
            CGRect(x: 0, y: 25, width: 1512, height: 920),
            CGRect(x: -1920, y: -180, width: 1920, height: 1080),
            CGRect(x: 300, y: 982, width: 2560, height: 1440),
            CGRect(x: 1512, y: -1400, width: 1920, height: 1200)
        ]
        for display in displays {
            let layout = WorkspaceLayout(visibleFrame: display)
            for frame in [layout.mainFrame, layout.leftPreviewFrame, layout.rightPreviewFrame, layout.railFrame] {
                XCTAssertGreaterThanOrEqual(frame.minX, display.minX)
                XCTAssertGreaterThanOrEqual(frame.minY, display.minY)
                XCTAssertLessThanOrEqual(frame.maxX, display.maxX + 0.0001)
                XCTAssertLessThanOrEqual(frame.maxY, display.maxY + 0.0001)
            }
            XCTAssertEqual(layout.mainFrame.minX - layout.leftPreviewFrame.maxX, 12, accuracy: 0.0001)
            XCTAssertEqual(layout.rightPreviewFrame.minX - layout.mainFrame.maxX, 12, accuracy: 0.0001)
            XCTAssertEqual(layout.leftPreviewFrame.width, layout.rightPreviewFrame.width, accuracy: 0.0001)
            XCTAssertGreaterThan(layout.mainFrame.minY, layout.railFrame.maxY)
        }
    }

    func testExpandedModeUsesPreviewSpaceButPreservesRail() {
        let screen = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        let regular = WorkspaceLayout(visibleFrame: screen)
        let expanded = WorkspaceLayout(visibleFrame: screen, expanded: true)
        XCTAssertEqual(regular.railFrame, expanded.railFrame)
        XCTAssertGreaterThan(expanded.mainFrame.width, regular.mainFrame.width)
        XCTAssertEqual(expanded.mainFrame.minX, regular.leftPreviewFrame.minX)
        XCTAssertEqual(expanded.mainFrame.maxX, regular.rightPreviewFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(expanded.leftPreviewFrame.width, 0)
        XCTAssertEqual(expanded.rightPreviewFrame.width, 0)
    }

    func testRatiosClampToSupportedRangeAndNonFiniteUsesDefault() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(WorkspaceLayout(visibleFrame: screen, mainRatio: 0.1),
                       WorkspaceLayout(visibleFrame: screen, mainRatio: 0.8))
        XCTAssertEqual(WorkspaceLayout(visibleFrame: screen, mainRatio: 1.5),
                       WorkspaceLayout(visibleFrame: screen, mainRatio: 0.9))
        XCTAssertEqual(WorkspaceLayout(visibleFrame: screen, mainRatio: .nan),
                       WorkspaceLayout(visibleFrame: screen))
    }

    func testAccessibilityConversionUsesPrimaryDisplayIncludingNegativeCoordinates() {
        let primaryHeight: CGFloat = 982
        let frames = [
            CGRect(x: 100, y: 80, width: 800, height: 600),
            CGRect(x: -1800, y: -160, width: 900, height: 800),
            CGRect(x: 200, y: 1100, width: 900, height: 800)
        ]
        for original in frames {
            let accessibility = WorkspaceLayout.accessibilityFrame(fromAppKit: original, primaryScreenHeight: primaryHeight)
            let restored = WorkspaceLayout.appKitFrame(fromAccessibility: accessibility, primaryScreenHeight: primaryHeight)
            XCTAssertEqual(restored, original)
            XCTAssertEqual(accessibility.minX, original.minX)
            XCTAssertEqual(accessibility.minY, primaryHeight - original.maxY)
        }
        XCTAssertEqual(WorkspaceLayout.accessibilityFrame(fromAppKit: frames[2], primaryScreenHeight: primaryHeight).minY, -918)
    }

    func testTinyVisibleAreasNeverProduceNegativeSizes() {
        for size: CGFloat in [0, 1, 20, 60] {
            let layout = WorkspaceLayout(visibleFrame: CGRect(x: -30, y: -40, width: size, height: size))
            for frame in [layout.mainFrame, layout.leftPreviewFrame, layout.rightPreviewFrame, layout.railFrame] {
                XCTAssertGreaterThanOrEqual(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.height, 0)
            }
        }
    }
}

final class SavedWindowFrameTests: XCTestCase {
    func testRecoveryDataPreservesNegativeDisplayCoordinatesAndMinimizedState() throws {
        let original = SavedWindowFrame(id: "pid:42-window:7", pid: 42, appBundleID: "com.example.Editor",
            title: "未儲存的筆記", frame: CGRect(x: -1800, y: -800, width: 900, height: 700), wasMinimized: true)
        let decoded = try JSONDecoder().decode(SavedWindowFrame.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
