import AppKit
import Foundation

private struct SmokeCheckResult: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct SmokeFrame: Encodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    init(_ frame: CGRect) {
        x = frame.minX; y = frame.minY; width = frame.width; height = frame.height
    }
}

private struct SmokeReport: Encodable {
    let schemaVersion = 2
    let scope = "native-demo-integration"
    let limitation = "App-owned NSWindow/NSTextView integration only. External application control, AX permission grants, ScreenCaptureKit capture, and global key delivery are not verified by this run."
    let completedAt: Date
    let passed: Bool
    let checks: [SmokeCheckResult]
    let originalFrames: [SmokeFrame]
    let restoredFrames: [SmokeFrame]
    let screenshotPath: String?
    let switchPerformance: SmokeSwitchPerformance
}

private struct SmokeSwitchPerformance: Encodable {
    let measurement = "Monotonic elapsed time from select() to settled native keyboard focus, including diagnostic polling. Successful switches only; no fixed latency pass/fail budget."
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double?
    let maximumMilliseconds: Double?
    init(_ samples: [Double]) {
        samplesMilliseconds = samples
        let sorted = samples.sorted()
        if sorted.isEmpty { medianMilliseconds = nil }
        else if sorted.count.isMultiple(of: 2) {
            medianMilliseconds = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else { medianMilliseconds = sorted[sorted.count / 2] }
        maximumMilliseconds = sorted.last
    }
}

/// Called only by the explicit --smoke-test launch mode; never manages external windows.
@MainActor
func runSmokeCheck(store: WorkspaceStore, managerWindow: NSWindow) async -> Bool {
    let arguments = ProcessInfo.processInfo.arguments
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    let reportURL = URL(fileURLWithPath: option("--report-path") ?? "/tmp/WindowLane-smoke.json")
    let screenshotURL = option("--screenshot-path").map { URL(fileURLWithPath: $0) }
    var checks: [SmokeCheckResult] = []
    var originals: [CGRect] = []
    var restored: [CGRect] = []
    var switchLatencies: [Double] = []
    var writtenScreenshot: String?
    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(SmokeCheckResult(name: name, passed: passed, detail: detail))
    }
    func finish() -> Bool {
        let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
        let report = SmokeReport(
            completedAt: Date(), passed: passed, checks: checks,
            originalFrames: originals.map(SmokeFrame.init), restoredFrames: restored.map(SmokeFrame.init),
            screenshotPath: writtenScreenshot,
            switchPerformance: SmokeSwitchPerformance(switchLatencies)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            print("WINDOWLANE_SMOKE \(passed ? "PASS" : "FAIL") \(reportURL.path)")
            return passed
        } catch {
            print("WINDOWLANE_SMOKE FAIL: cannot write report: \(error.localizedDescription)")
            return false
        }
    }

    guard !store.isRunning, !store.isBusy, store.entries.isEmpty, store.pendingRecovery.isEmpty else {
        record("isolated_startup", false, "Smoke mode requires a fresh manager and no pending external-window recovery.")
        return finish()
    }
    record("isolated_startup", true)
    store.loadDemo()
    let windows = store.fixtures.windows
    record("three_native_editable_windows", windows.count == 3 && store.ordered.count == 3 && store.isDemo)
    guard windows.count == 3 else { return finish() }
    originals = windows.map(\.frame)

    let editors = windows.compactMap { ($0.contentView as? NSScrollView)?.documentView as? NSTextView }
    record("native_editors", editors.count == 3)
    guard editors.count == 3 else { store.clearDemo(); return finish() }
    let drafts = editors.enumerated().map { index, editor in
        editor.string + "\nUnsent smoke-test draft \(index + 1): 日本語・中文・English.\n"
    }
    let selections = editors.enumerated().map { NSRange(location: 2 + $0.offset, length: 8) }
    for (index, editor) in editors.enumerated() {
        editor.string = drafts[index]
        editor.setSelectedRange(selections[index])
        windows[index].makeFirstResponder(editor)
    }

    let originalIDs = store.order.ids
    func allManagedWindowsReady() -> Bool {
        let managed = store.ordered.compactMap(\.native)
        return !managed.isEmpty && managed.allSatisfy {
            $0.isVisible && !$0.isMiniaturized && smokeSameFrame($0.frame, store.layout.mainFrame)
        }
    }
    func noteSwitchLatency(startedAt: TimeInterval, destination: String, settled: Bool) {
        guard settled, store.isRunning, store.order.activeID == destination,
              let window = store.entries[destination]?.native, NSApp.keyWindow === window else { return }
        switchLatencies.append((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }
    store.move(originalIDs[0], to: 2)
    record("reorder_preserves_active_identity", store.order.ids == [originalIDs[1], originalIDs[2], originalIDs[0]] && store.order.activeID == originalIDs[0])

    managerWindow.makeKeyAndOrderFront(nil)
    try? await Task.sleep(nanoseconds: 220_000_000)
    if let screenshotURL {
        do {
            guard let view = managerWindow.contentView else { throw CocoaError(.fileWriteUnknown) }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: screenshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: screenshotURL, options: .atomic)
            writtenScreenshot = screenshotURL.path
            record("manager_native_render", bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "\(bitmap.pixelsWide) × \(bitmap.pixelsHigh) PNG, rendered from own content view without screen capture.")
        } catch {
            record("manager_native_render", false, error.localizedDescription)
        }
    }

    store.start()
    record("start_settles", await smokeWaitUntilSettled(store), store.status)
    record("workspace_running", store.isRunning && store.isDemo)
    guard store.isRunning else { store.stop(); store.fixtures.close(); return finish() }
    record("active_window_main_frame", smokeSameFrame(windows[0].frame, store.layout.mainFrame), "AppKit frame tolerance: 1 point.")
    record("all_windows_open_unminimized_at_main_frame", allManagedWindowsReady(), "All managed windows stay ready behind the active window; no per-switch parking.")

    var switchStarted = ProcessInfo.processInfo.systemUptime
    store.select(index: 0)
    let selectSettled = await smokeWaitUntilSettled(store)
    noteSwitchLatency(startedAt: switchStarted, destination: originalIDs[1], settled: selectSettled)
    record("select_settles", selectSettled, store.status)
    record("select_uses_reordered_identity", store.order.activeID == originalIDs[1])
    record("selected_window_key_and_editable", NSApp.keyWindow === windows[1] && windows[1].firstResponder === editors[1],
           smokeFocusDetail(expectedWindow: windows[1], expectedResponder: editors[1], activeID: store.order.activeID))
    record("switch_keeps_all_windows_ready", allManagedWindowsReady())

    switchStarted = ProcessInfo.processInfo.systemUptime
    store.step(1)
    let stepSettled = await smokeWaitUntilSettled(store)
    noteSwitchLatency(startedAt: switchStarted, destination: originalIDs[2], settled: stepSettled)
    record("step_settles", stepSettled, store.status)
    record("next_window_selected", store.order.activeID == originalIDs[2])
    switchStarted = ProcessInfo.processInfo.systemUptime
    store.select(originalIDs[0])
    let returnSettled = await smokeWaitUntilSettled(store)
    noteSwitchLatency(startedAt: switchStarted, destination: originalIDs[0], settled: returnSettled)
    record("return_settles", returnSettled, store.status)
    record("input_focus_returns", NSApp.keyWindow === windows[0] && windows[0].firstResponder === editors[0],
           smokeFocusDetail(expectedWindow: windows[0], expectedResponder: editors[0], activeID: store.order.activeID))
    record("drafts_and_selections_survive_switches", editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })

    let normalFrame = windows[0].frame
    store.toggleExpanded()
    record("expanded_aligns_all_windows_to_content_area", await smokeWaitUntilSettled(store) && store.expanded && allManagedWindowsReady() && windows.allSatisfy { $0.frame.width > normalFrame.width })
    store.toggleExpanded()
    record("expanded_restores_all_normal_frames", await smokeWaitUntilSettled(store) && !store.expanded && allManagedWindowsReady() && windows.allSatisfy { smokeSameFrame($0.frame, normalFrame) })

    store.stop()
    await store.waitForRestoration()
    restored = windows.map(\.frame)
    record("stop_clears_running_state", !store.isRunning && !store.isBusy && !store.expanded)
    record("stop_restores_all_original_frames", restored == originals, "Exact equality with the three original AppKit frames.")
    record("stop_keeps_documents_open", windows.allSatisfy(\.isVisible))
    record("stop_keeps_drafts_and_selections", editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })
    let countBeforeRemoval = store.ordered.count
    store.remove(originalIDs[1])
    record("removing_does_not_close_document", store.ordered.count == countBeforeRemoval - 1 && windows[1].isVisible && editors[1].string == drafts[1])

    store.start()
    store.stop()
    await store.waitForRestoration()
    await Task.yield()
    record("cancel_start_has_no_late_mutation", !store.isRunning && !store.isBusy && windows.map(\.frame) == originals)
    store.start()
    record("restart_after_cancel", await smokeWaitUntilSettled(store) && store.isRunning)
    let nextID = store.order.ids.first { $0 != store.order.activeID }
    if let nextID { store.select(nextID) }
    let selectedWhenStopping = store.order.activeID
    store.stop()
    await store.waitForRestoration()
    let focusedAfterRestoration = NSApp.keyWindow
    await Task.yield()
    record("cancel_immediate_focus_handoff_has_no_late_commit", !store.isRunning && !store.isBusy && store.order.activeID == selectedWhenStopping && NSApp.keyWindow === focusedAfterRestoration && windows.map(\.frame) == originals && windows.allSatisfy { $0.isVisible && !$0.isMiniaturized })
    store.start()
    let restarted = await smokeWaitUntilSettled(store) && store.isRunning
    var burstSafe = restarted
    var switchGeometryUnchanged = restarted
    var burstDetails: [String] = []
    if restarted {
        let managed = store.ordered.compactMap(\.native)
        let baselineFrames = managed.map(\.frame)
        let baselineMinimized = managed.map(\.isMiniaturized)
        for index in 0..<8 {
            let destination = index % store.order.ids.count
            let destinationID = store.order.ids[destination]
            switchStarted = ProcessInfo.processInfo.systemUptime
            store.select(index:destination)
            store.select(index:(destination + 1) % store.order.ids.count)
            let settled = await smokeWaitUntilSettled(store)
            noteSwitchLatency(startedAt: switchStarted, destination: destinationID, settled: settled)
            let expectedWindow = store.entries[destinationID]?.native
            let expectedEditor = (expectedWindow?.contentView as? NSScrollView)?.documentView as? NSTextView
            burstDetails.append("iteration=\(index), settled=\(settled), expectedID=\(destinationID), actualID=\(store.order.activeID ?? "nil"), identityMatches=\(store.order.activeID == destinationID); "
                                + smokeFocusDetail(expectedWindow: expectedWindow, expectedResponder: expectedEditor, activeID: store.order.activeID))
            burstSafe = settled && store.isRunning && store.order.activeID == destinationID
                && NSApp.keyWindow === store.entries[destinationID]?.native && burstSafe
            switchGeometryUnchanged = switchGeometryUnchanged && managed.map(\.frame) == baselineFrames
                && managed.map(\.isMiniaturized) == baselineMinimized && allManagedWindowsReady()
        }
    }
    record("repeated_switches_ignore_busy_input", burstSafe, burstDetails.joined(separator: "\n"))
    record("repeated_switches_preserve_geometry_and_minimized_state", switchGeometryUnchanged, "All managed native frames and minimized flags equal their post-start baseline after each direct focus switch.")
    store.stop(); await store.waitForRestoration()
    record("repeated_switches_restore_documents", windows.map(\.frame) == originals && editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })

    // These documents were created only for this explicitly requested smoke run.
    store.fixtures.close()
    return finish()
}

@MainActor
private func smokeWaitUntilSettled(_ store: WorkspaceStore) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while store.isBusy && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return !store.isBusy
}

private func smokeSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
        && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
}

/// Read-only diagnostics identify input ownership without including document text.
@MainActor
private func smokeFocusDetail(expectedWindow: NSWindow?, expectedResponder: NSResponder?, activeID: String?) -> String {
    func windowDescription(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(String(reflecting: type(of: window)))#\(window.windowNumber)[\(window.title)] key=\(window.isKeyWindow) main=\(window.isMainWindow) visible=\(window.isVisible) minimized=\(window.isMiniaturized)"
    }
    func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return "\(String(reflecting: type(of: responder)))@\(ObjectIdentifier(responder))"
    }
    let expectedActualResponder = expectedWindow?.firstResponder
    let keyedWindows = NSApp.windows.filter(\.isKeyWindow).map { "\(String(reflecting: type(of: $0)))#\($0.windowNumber)" }.joined(separator: ",")
    return "appActive=\(NSApp.isActive), frontmostBundle=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"), activeID=\(activeID ?? "nil"); "
        + "expectedWindow={\(windowDescription(expectedWindow))}; actualKeyWindow={\(windowDescription(NSApp.keyWindow))}; actualMainWindow={\(windowDescription(NSApp.mainWindow))}; keyedWindowFlags=[\(keyedWindows)]; "
        + "expectedResponder=\(responderDescription(expectedResponder)), expectedWindowActualResponder=\(responderDescription(expectedActualResponder)), responderMatches=\(expectedActualResponder === expectedResponder); "
        + "keyWindowActualResponder=\(responderDescription(NSApp.keyWindow?.firstResponder))"
}
