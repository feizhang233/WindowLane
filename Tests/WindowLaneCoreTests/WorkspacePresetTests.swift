import XCTest
@testable import WindowLaneCore

final class WorkspacePresetMatcherTests: XCTestCase {
    private func window(_ id: String, title: String = "Document", bundle: String? = "com.example.Editor",
                        pid: Int32? = 42, cg: UInt32? = 101, launch: Double? = 100,
                        demo: Int? = nil) -> WorkspaceWindowDescriptor {
        WorkspaceWindowDescriptor(id: id, bundleIdentifier: bundle, appName: "Editor", title: title,
                                  processID: pid, windowID: cg, launchTime: launch, nativeDemoIndex: demo)
    }
    private func preset(_ windows: [WorkspaceWindowDescriptor]) -> WorkspacePreset {
        WorkspacePreset(name: "Research", windows: windows)
    }

    func testSameSessionIdentitySurvivesTitleChange() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old", title: "Unsaved")]),
                                                   among: [window("current", title: "Saved draft")])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.matchedIDs, ["current"])
        XCTAssertEqual(result.slots.first?.kind, .sameSession)
    }

    func testRestartUsesUniqueExactBundleAndTitle() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old")]),
                                                   among: [window("current", pid: 75, cg: 202, launch: 500)])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.slots.first?.kind, .exactTitle)
    }

    func testReusedPIDAndWindowIDDoNotMatchChangedDocument() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old", title: "Original")]),
                                                   among: [window("new", title: "Replacement", launch: 200)])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.slots.first?.kind, .missing)
        XCTAssertEqual(result.unresolvedLabels, ["Editor — Original"])
    }

    func testDuplicateTitlesAreResolvedOnlyBySessionIdentity() {
        let saved = [window("first", cg: 10), window("second", cg: 20)]
        let current = [window("second-now", cg: 20), window("first-now", cg: 10)]
        let result = WorkspacePresetMatcher.resolve(preset(saved), among: current)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.matchedIDs, ["first-now", "second-now"])
        XCTAssertEqual(result.slots.map(\.kind), [.sameSession, .sameSession])
    }

    func testAmbiguousRestartNeverChoosesTheFirstTitle() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old")]), among: [
            window("new-a", pid: 75, cg: 201, launch: 500),
            window("new-b", pid: 75, cg: 202, launch: 500)
        ])
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.matchedIDs.isEmpty)
        XCTAssertEqual(result.slots.first?.kind, .ambiguous)
    }

    func testDifferentApplicationCannotReplaceAnIdenticalTitle() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old")]),
                                                   among: [window("new", bundle: "com.other.Editor")])
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.matchedIDs.isEmpty)
    }

    func testEmptyTitleAndMissingBundleCannotUseRestartMatching() {
        for saved in [window("old", title: ""), window("old", bundle: nil)] {
            let result = WorkspacePresetMatcher.resolve(preset([saved]),
                                                       among: [window("new", pid: 75, cg: 202, launch: 500)])
            XCTAssertFalse(result.isComplete)
            XCTAssertEqual(result.slots.first?.kind, .unidentifiable)
        }
    }

    func testRuntimeIDAloneDoesNotBypassIdentityChecks() {
        let result = WorkspacePresetMatcher.resolve(preset([window("same-id", title: "Original")]),
                                                   among: [window("same-id", title: "Other", pid: 75, launch: 500)])
        XCTAssertFalse(result.isComplete)
    }

    func testTwoSavedSlotsCannotResolveToOneCurrentWindow() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old-a", cg: 10), window("old-b", cg: 20)]),
                                                   among: [window("current", pid: 75, cg: 202, launch: 500)])
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.matchedIDs.isEmpty)
        XCTAssertEqual(result.slots.map(\.kind), [.ambiguous, .ambiguous])
    }

    func testPartialMatchIsReportedWithoutBecomingACompleteWorkspace() {
        let result = WorkspacePresetMatcher.resolve(preset([window("a", cg: 10), window("b", title: "Closed", cg: 20)]),
                                                   among: [window("a-current", cg: 10)])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.matchedIDs, ["a-current"])
        XCTAssertEqual(result.unresolvedLabels, ["Editor — Closed"])
    }

    func testAmbiguousSessionIdentityDoesNotFallbackToAUniqueTitle() {
        let result = WorkspacePresetMatcher.resolve(preset([window("old")]),
                                                   among: [window("a"), window("b", title: "Renamed")])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.slots.first?.kind, .ambiguous)
    }

    func testDemoSlotsOnlyMatchExplicitNativeDemoDescriptors() {
        let saved = window("demo-1", demo: 1)
        let external = window("external", title: saved.title)
        XCTAssertFalse(WorkspacePresetMatcher.resolve(preset([saved]), among: [external]).isComplete)
        let result = WorkspacePresetMatcher.resolve(preset([saved]), among: [window("demo-now", demo: 1), external])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.matchedIDs, ["demo-now"])
        XCTAssertEqual(result.slots.first?.kind, .nativeDemo)
    }
}

final class WorkspacePresetRepositoryTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("workspaces.json") }
    private let windows = [
        WorkspaceWindowDescriptor(id: "notes", bundleIdentifier: "com.example.Editor", appName: "Editor", title: "Notes"),
        WorkspaceWindowDescriptor(id: "reference", bundleIdentifier: "com.example.Reader", appName: "Reader", title: "Reference")
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WindowLane-preset-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testSaveReloadPreservesNamesOrderLayoutScreenAndFractionalPage() throws {
        let repository = WorkspacePresetRepository(url: url)
        let saved = try repository.save(name: "  資料整理  ", windows: Array(windows.reversed()), mainRatio: 0.88,
                                        displayID: 987, displayName: "DELL", activeSlot: 1, pagePosition: 0.5)
        let reloaded = WorkspacePresetRepository(url: url)
        XCTAssertNil(reloaded.readError)
        XCTAssertEqual(reloaded.items, [saved])
        XCTAssertEqual(saved.name, "資料整理")
        XCTAssertEqual(saved.windows.map(\.id), ["reference", "notes"])
        XCTAssertEqual(saved.mainRatio, 0.88)
        XCTAssertEqual(saved.displayID, 987)
        XCTAssertEqual(saved.displayName, "DELL")
        XCTAssertEqual(saved.activeSlot, 1)
        XCTAssertEqual(saved.effectivePagePosition, 0.5)
    }

    func testUpdateAndRenamePreserveIdentityAndCreationDate() throws {
        var clock = Date(timeIntervalSince1970: 100)
        let repository = WorkspacePresetRepository(url: url, now: { clock })
        let first = try repository.save(name: "Notes", windows: windows)
        clock = Date(timeIntervalSince1970: 200)
        let updated = try repository.save(name: "Notes", windows: [windows[1]], activeSlot: 0, replacing: first.id)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.createdAt, first.createdAt)
        XCTAssertEqual(updated.updatedAt, clock)
        clock = Date(timeIntervalSince1970: 300)
        try repository.rename(first.id, to: "Reading")
        XCTAssertEqual(repository.items.count, 1)
        XCTAssertEqual(repository.items[0].id, first.id)
        XCTAssertEqual(repository.items[0].createdAt, first.createdAt)
        XCTAssertEqual(repository.items[0].updatedAt, clock)
        XCTAssertEqual(repository.items[0].windows, [windows[1]])
    }

    func testDeletionCanBeUndoneWithoutRecreatingIdentity() throws {
        let repository = WorkspacePresetRepository(url: url)
        let first = try repository.save(name: "First", windows: windows)
        let second = try repository.save(name: "Second", windows: [windows[0]])
        let deleted = try repository.delete(first.id)
        XCTAssertEqual(deleted, first)
        XCTAssertEqual(repository.items, [second])
        try repository.restore(deleted)
        XCTAssertEqual(Set(repository.items.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(WorkspacePresetRepository(url: url).items.contains(first))
    }

    func testDuplicateNameAndInvalidNameKeepAcceptedFileUnchanged() throws {
        let repository = WorkspacePresetRepository(url: url)
        let first = try repository.save(name: "Research", windows: windows)
        let original = try Data(contentsOf: url)
        for name in [" research ", "", "   ", "Line\nBreak", String(repeating: "字", count: 81)] {
            XCTAssertThrowsError(try repository.save(name: name, windows: windows))
            XCTAssertEqual(repository.items, [first])
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testSixWindowBoundAndDuplicateWindowValidationPreserveAcceptedPreset() throws {
        let repository = WorkspacePresetRepository(url: url)
        let saved = try repository.save(name: "Daily", windows: windows)
        let original = try Data(contentsOf: url)
        let seven = (0..<7).map { WorkspaceWindowDescriptor(id: "w\($0)", appName: "App", title: "Title \($0)") }
        for invalid in [[], [windows[0], windows[0]], seven,
                        [WorkspaceWindowDescriptor(id: "", appName: "App", title: "Window")]] {
            XCTAssertThrowsError(try repository.save(name: "Daily", windows: invalid, replacing: saved.id))
            XCTAssertEqual(repository.items, [saved])
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testPresetCapacityAllowsUpdatingAnExistingItemAtTheLimit() throws {
        let repository = WorkspacePresetRepository(url: url)
        for index in 0..<24 { try repository.save(name: "Preset \(index)", windows: windows) }
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try repository.save(name: "Extra", windows: windows)) {
            XCTAssertEqual($0 as? WorkspacePresetError, .collectionFull)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let first = repository.items[0]
        try repository.save(name: "Updated", windows: [windows[1]], replacing: first.id)
        XCTAssertEqual(repository.items.count, 24)
        XCTAssertEqual(repository.items[0].id, first.id)
        XCTAssertEqual(repository.items[0].name, "Updated")
    }

    func testCorruptArchiveRemainsUntouchedAndBlocksWrites() throws {
        let invalid = Data("{broken json".utf8)
        try invalid.write(to: url)
        let repository = WorkspacePresetRepository(url: url)
        XCTAssertNotNil(repository.readError)
        XCTAssertTrue(repository.items.isEmpty)
        XCTAssertThrowsError(try repository.save(name: "New", windows: windows)) {
            XCTAssertEqual($0 as? WorkspacePresetError, .unreadableArchive)
        }
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testUnsupportedArchiveVersionPreservesFutureData() throws {
        let future = Data(#"{"version":2,"presets":[]}"#.utf8)
        try future.write(to: url)
        let repository = WorkspacePresetRepository(url: url)
        XCTAssertNotNil(repository.readError)
        XCTAssertThrowsError(try repository.save(name: "New", windows: windows))
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testFailedReloadRetainsLastAcceptedItemsThenCanRecover() throws {
        let repository = WorkspacePresetRepository(url: url)
        let saved = try repository.save(name: "Keep", windows: windows)
        let valid = try Data(contentsOf: url)
        try Data("corruption".utf8).write(to: url)
        XCTAssertThrowsError(try repository.reload())
        XCTAssertEqual(repository.items, [saved])
        XCTAssertNotNil(repository.readError)
        try valid.write(to: url)
        try repository.reload()
        XCTAssertNil(repository.readError)
        XCTAssertEqual(repository.items, [saved])
    }

    func testFailedAtomicWriteDoesNotPublishNewCollection() throws {
        let repository = WorkspacePresetRepository(url: url)
        let saved = try repository.save(name: "Keep", windows: windows)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try repository.save(name: "Should fail", windows: windows))
        XCTAssertEqual(repository.items, [saved])
        XCTAssertNil(repository.readError)
    }

    func testMissingPagePositionDecodesToActiveSlotAndBoundsFiniteValues() throws {
        let repository = WorkspacePresetRepository(url: url)
        let saved = try repository.save(name: "Old", windows: windows, mainRatio: .nan, activeSlot: 1)
        XCTAssertEqual(saved.mainRatio, 0.84)
        XCTAssertNil(saved.pagePosition)
        XCTAssertEqual(saved.effectivePagePosition, 1)
        XCTAssertEqual(WorkspacePresetRepository(url: url).items[0].effectivePagePosition, 1)
        let invalid = WorkspacePreset(name: "Bounded", windows: windows, mainRatio: 2, activeSlot: 99, pagePosition: .nan)
        XCTAssertEqual(invalid.mainRatio, 0.9)
        XCTAssertEqual(invalid.activeSlot, 1)
        XCTAssertEqual(invalid.pagePosition, 1)
        XCTAssertEqual(WorkspacePreset(name: "Bounded", windows: windows, pagePosition: -4).pagePosition, 0)
        XCTAssertEqual(WorkspacePreset(name: "Bounded", windows: windows, pagePosition: 20).pagePosition, 1)
    }
}
