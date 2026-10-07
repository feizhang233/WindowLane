import AppKit
import WindowLaneCore

/// Explicit compatibility diagnosis: only one existing Obsidian window and one
/// disposable app-owned editor. Never edits notes, changes settings or reads text.
@MainActor
func runObsidianSizingCheck(store: WorkspaceStore) async -> Bool {
    struct Check: Encodable { let name: String; let passed: Bool; let detail: String }
    struct Report: Encodable {
        let completedAt: Date
        let passed: Bool
        let scope = "one-existing-obsidian-window-and-disposable-native-fixture"
        let checks: [Check]
    }
    let arguments = CommandLine.arguments
    guard arguments.contains("--obsidian-smoke-test") else { return false }
    let pathIndex = arguments.firstIndex(of: "--report-path")
    let path = pathIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        ?? "/tmp/WindowLane-obsidian-smoke.json"
    var checks: [Check] = []
    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(Check(name: name, passed: passed, detail: detail))
    }
    func finish() -> Bool {
        let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(Report(completedAt: Date(), passed: passed, checks: checks)).write(to: url, options: .atomic)
        } catch { return false }
        return passed
    }
    func settle() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while store.isBusy && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !store.isBusy
    }
    func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
    record("existing_accessibility_permission", store.backend.isTrusted)
    guard store.backend.isTrusted, !store.isRunning, store.pendingRecovery.isEmpty else { return finish() }
    let matches = store.backend.listWindows().filter { $0.bundleIdentifier == "md.obsidian" }
    record("exactly_one_existing_obsidian_window", matches.count == 1)
    guard matches.count == 1, let candidate = matches.first,
          let original = store.backend.frame(of: candidate),
          let minimized = store.backend.isMinimized(candidate) else { return finish() }
    store.add(candidate)
    store.fixtures.show()
    guard let native = store.fixtures.windows.first else { return finish() }
    let originalNative = native.frame
    let fixture = ManagedWindow(native: native, index: 0)
    store.entries[fixture.id] = fixture
    store.order = WorkspaceOrder(ids: [fixture.id, candidate.id], activeID: fixture.id)
    store.pagePosition = 0
    // Use the widest single-page setting so the neighboring pane reaches the
    // generic 320-point bound even on this host's large display. Isolated prefs.
    store.ratio = 0.9
    store.start()
    let started = await settle() && store.isRunning
    record("workspace_starts_with_real_obsidian_window", started, store.status)
    if started {
        let requested = BookPageLayout(visibleFrame: store.screen.visibleFrame, mainRatio: store.ratio, position: 0.01, count: 2)
        let narrowWidth = requested.frames[1]?.width ?? 0
        store.commitContinuousPaging(position: 0.01)
        let committed = await settle()
        let actual = store.backend.frame(of: candidate)
        let expected = WorkspaceLayout.accessibilityFrame(fromAppKit: store.frameForWindow(candidate.id),
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        record("narrow_obsidian_pane_keeps_workspace_running", committed && store.isRunning && store.isSplit
               && abs(store.pagePosition - 0.01) < 0.0001 && !store.isError, store.status)
        record("obsidian_actual_geometry_matches_adapted_layout", actual.map { sameFrame($0, expected) } == true,
               "initial requested width=\(narrowWidth); accepted width=\(actual?.width ?? 0)")
        record("obsidian_and_fixture_do_not_overlap", native.frame.maxX <= store.frameForWindow(candidate.id).minX)
        let before = store.backend.diagnostics
        store.select(candidate.id)
        let switched = await settle()
        record("obsidian_can_receive_keyboard_focus_after_split", switched && store.isRunning
               && store.order.activeID == candidate.id && store.backend.isFocused(candidate), store.status)
        store.select(fixture.id)
        let returned = await settle()
        record("cross_application_switch_returns_to_native_editor", returned && store.isRunning && native.isKeyWindow)
        let prepared = store.backend.diagnostics
        store.select(candidate.id)
        _ = await settle()
        record("prepared_single_page_switch_has_no_geometry_writes", store.isRunning
               && store.backend.diagnostics.sizeWrites == prepared.sizeWrites
               && store.backend.diagnostics.positionWrites == prepared.positionWrites
               && store.backend.diagnostics.minimizedWrites == prepared.minimizedWrites,
               "Split-to-single alignment is measured separately from the prepared single-page switch; baseline size writes=\(before.sizeWrites).")
    }
    store.stop()
    await store.waitForRestoration()
    record("obsidian_original_frame_and_minimized_state_restored", store.backend.frame(of: candidate).map { sameFrame($0, original) } == true
           && store.backend.isMinimized(candidate) == minimized && store.pendingRecovery.isEmpty, store.status)
    record("native_fixture_original_frame_restored", sameFrame(native.frame, originalNative))
    store.fixtures.close()
    return finish()
}
