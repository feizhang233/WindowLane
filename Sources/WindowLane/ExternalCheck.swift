import AppKit
import ApplicationServices
import Foundation

private struct ExternalCheckResult: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct ExternalFrame: Encodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    init(_ frame: CGRect) {
        x = frame.minX; y = frame.minY; width = frame.width; height = frame.height
    }
}

private struct ExternalWindowState: Encodable {
    let id: String
    let title: String
    let pid: Int32
    let cgWindowID: UInt32?
    let frame: ExternalFrame?
    let minimized: Bool?
}

private struct ExternalReport: Encodable {
    let schemaVersion = 2
    let scope = "external-AX-integration"
    let fixtureBundleID = "com.feizhang.windowlane.fixture"
    let limitation = "Only the three documents of the separate fixture application are managed. ScreenCaptureKit pixel output is checked only if permission was already granted; visual correspondence, other applications, content preservation and hardware shortcut delivery are outside this test. No system permission is requested."
    let completedAt: Date
    let status: String
    let reason: String?
    let passed: Bool
    let screenCaptureAuthorizedAtStart: Bool
    let screenCaptureTest: String
    let checks: [ExternalCheckResult]
    let originalStates: [ExternalWindowState]
    let restoredStates: [ExternalWindowState]
    let switchPerformance: ExternalSwitchPerformance
}

private struct ExternalSwitchPerformance: Encodable {
    let measurement = "Monotonic elapsed time from select() to settled system-wide AX keyboard focus, including diagnostic polling and AX readback. Successful switches only; no fixed cross-application latency pass/fail budget."
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

/// This path never acts on user applications, even when they share a fixture title.
/// Both the explicit launch argument and the dedicated fixture bundle are required.
@MainActor
func runExternalCheck(store: WorkspaceStore) async -> Bool {
    let arguments = ProcessInfo.processInfo.arguments
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    let reportURL = URL(fileURLWithPath: option("--report-path") ?? "/tmp/WindowLane-external-smoke.json")
    let fixtureID = "com.feizhang.windowlane.fixture"
    let titles = ["Document A · 閱讀測試", "Document B · 草稿測試", "Document C · 日語測試"]
    var checks: [ExternalCheckResult] = []
    var originals: [ExternalWindowState] = []
    var restored: [ExternalWindowState] = []
    var switchLatencies: [Double] = []
    var blockedReason: String?
    let captureAuthorized = store.capture.isAuthorized
    var captureTest = "unverified"
    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(ExternalCheckResult(name: name, passed: passed, detail: detail))
    }
    func finish() -> Bool {
        let passed = blockedReason == nil && !checks.isEmpty && checks.allSatisfy(\.passed)
        let status = blockedReason != nil ? "blocked" : (passed ? "passed" : "failed")
        let report = ExternalReport(completedAt: Date(), status: status, reason: blockedReason,
                                    passed: passed, screenCaptureAuthorizedAtStart: captureAuthorized,
                                    screenCaptureTest: captureTest, checks: checks,
                                    originalStates: originals, restoredStates: restored,
                                    switchPerformance: ExternalSwitchPerformance(switchLatencies))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            print("WINDOWLANE_EXTERNAL_SMOKE \(status.uppercased()) \(reportURL.path)")
            return passed
        } catch {
            print("WINDOWLANE_EXTERNAL_SMOKE FAIL: cannot write report: \(error.localizedDescription)")
            return false
        }
    }
    guard arguments.contains("--external-smoke-test") else {
        blockedReason = "The explicit --external-smoke-test argument is required. No windows were changed."
        return finish()
    }
    guard store.backend.isTrusted else {
        blockedReason = "No system Accessibility permission is granted to this WindowLane application. The test did not request permission or modify any window."
        record("accessibility_permission", false, "AXIsProcessTrusted() returned false.")
        return finish()
    }
    record("accessibility_permission", true)
    record("optional_screen_capture_permission", true, captureAuthorized
        ? "Already granted; all three pre-layout snapshots must contain nonempty pixels."
        : "Not granted; ScreenCaptureKit remains unverified. Core AX tests continue without requesting permission.")
    guard !store.isRunning, !store.isBusy, !store.isDemo,
          store.entries.isEmpty, store.pendingRecovery.isEmpty else {
        blockedReason = "External diagnostics require a fresh manager with no existing workspace or pending recovery. No windows were changed."
        return finish()
    }
    record("isolated_startup", true)
    let fixtureApps = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID)
        .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    guard fixtureApps.count == 1, let fixtureApp = fixtureApps.first else {
        blockedReason = "Exactly one separate com.feizhang.windowlane.fixture application must be running with --fixture-host. No windows were changed."
        return finish()
    }
    let listed = store.backend.listWindows().filter { $0.pid == fixtureApp.processIdentifier && titles.contains($0.title) }
    let candidates = titles.compactMap { title in
        let matches = listed.filter { $0.title == title }
        return matches.count == 1 ? matches.first : nil
    }
    guard candidates.count == 3, Set(candidates.map(\.id)).count == 3 else {
        blockedReason = "Could not uniquely identify all three resizable Document A/B/C fixture windows. No windows were changed."
        return finish()
    }
    record("fixture_only_scope", candidates.allSatisfy {
        NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == fixtureID
    }, "Three AX objects in process \(fixtureApp.processIdentifier); own application and all other bundles excluded.")

    originals = candidates.map { externalState($0, backend: store.backend) }
    guard originals.allSatisfy({ $0.frame != nil && $0.minimized != nil }) else {
        blockedReason = "Fixture geometry or minimized state could not be read. No windows were changed."
        return finish()
    }
    let repeated = store.backend.listWindows().filter { $0.pid == fixtureApp.processIdentifier && titles.contains($0.title) }
    record("stable_AX_identity_across_discovery", candidates.allSatisfy { candidate in
        let matches = repeated.filter { $0.title == candidate.title }
        return matches.count == 1 && matches[0].id == candidate.id
    })
    for candidate in candidates { store.add(candidate) }
    record("three_external_windows_added", store.ordered.count == 3 && !store.isDemo
        && store.ordered.allSatisfy { $0.native == nil && $0.candidate?.pid == fixtureApp.processIdentifier })
    guard store.ordered.count == 3 else { return finish() }

    // Snapshot capture is bounded separately; 15 seconds accommodates all three
    // optional two-second captures plus initial native window alignment.
    store.start()
    record("start_settles", await externalWait(timeout: 15) { !store.isBusy }, store.status)
    record("workspace_running", store.isRunning && !store.isDemo, store.status)
    if captureAuthorized {
        var allSnapshotsHavePixels = true
        for (index, candidate) in candidates.enumerated() {
            // start() captures each unminimized original before arranging any
            // window; the same NSImage is then used by the real edge preview.
            let snapshot = store.entries[candidate.id]?.snapshot
            let bitmap = snapshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let valid = (bitmap?.width ?? 0) > 0 && (bitmap?.height ?? 0) > 0
            allSnapshotsHavePixels = allSnapshotsHavePixels && valid
            record("screen_capture_\(index)_nonempty_pixels", valid,
                   bitmap.map { "\($0.width) × \($0.height) pixels from the pre-layout ScreenCaptureKit snapshot." }
                    ?? "No snapshot returned despite an existing capture permission; timeout, privacy filtering or capture failure remains visible as a failed check.")
        }
        captureTest = allSnapshotsHavePixels ? "pixel-output-verified" : "failed"
        if store.isRunning, let first = candidates.first {
            // A main-sized window exceeds the former 1100-pixel thumbnail cap.
            // Check the real capture at the target screen's native pixel density.
            let frame = store.backend.frame(of: first) ?? store.mainAXFrame
            let density = store.screen.backingScaleFactor
            let fullSizeSnapshot = await store.capture.capture(first)
            let bitmap = fullSizeSnapshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let nativeResolution = bitmap.map {
                $0.width >= Int((frame.width * density).rounded(.down))
                    && $0.height >= Int((frame.height * density).rounded(.down))
            } ?? false
            record("main_window_capture_native_resolution", nativeResolution,
                   bitmap.map { "\($0.width) × \($0.height) pixels; workspace \(Int(frame.width)) × \(Int(frame.height)) points at \(density)x screen scale." }
                    ?? "No full-sized workspace snapshot returned.")
            let logicalSizeCorrect = fullSizeSnapshot.map {
                abs($0.size.width - frame.width) < 2 && abs($0.size.height - frame.height) < 2
            } ?? false
            record("main_window_capture_logical_size", logicalSizeCorrect,
                   "NSImage point size must match the live window so the edge crop never stretches a thumbnail.")
            if !nativeResolution || !logicalSizeCorrect { captureTest = "failed" }
        }
    }

    func allExternalWindowsReady() -> Bool {
        candidates.allSatisfy { candidate in
            store.backend.frame(of: candidate).map { externalSameFrame($0, store.mainAXFrame) } == true
                && store.backend.isMinimized(candidate) == false
        }
    }
    if store.isRunning {
        record("all_windows_start_open_unminimized_at_main_frame", allExternalWindowsReady(), "All three AX windows remain unminimized at the shared workspace frame.")
        let warmFrames = candidates.map { store.backend.frame(of: $0) }
        let warmMinimized = candidates.map { store.backend.isMinimized($0) }
        let warmDiagnostics = store.backend.diagnostics
        var geometryUnchanged = true
        for (step, index) in [0, 1, 2, 0, 2, 1, 0].enumerated() {
            let switchStarted = ProcessInfo.processInfo.systemUptime
            if step > 0 { store.select(index: index) }
            let settled = await externalWait(timeout: 6) { !store.isBusy }
            record("switch_\(step)_settles", settled && store.isRunning, store.status)
            guard settled, store.isRunning else { break }
            let expected = candidates[index]
            let expectedFrame = store.mainAXFrame
            let focused = await externalWait(timeout: 2) { externalFocusedWindowIs(expected) }
            if step > 0, focused, store.order.activeID == expected.id {
                switchLatencies.append((ProcessInfo.processInfo.systemUptime - switchStarted) * 1_000)
            }
            record("switch_\(step)_real_keyboard_focus", focused, "System-wide AX focused application + focused window must equal \(expected.title).")
            record("switch_\(step)_active_identity", store.order.activeID == expected.id)
            record("switch_\(step)_actual_main_frame", store.backend.frame(of: expected).map { externalSameFrame($0, expectedFrame) } ?? false,
                   "Live AX frame compared with workspace geometry; tolerance 4 points.")
            record("switch_\(step)_all_windows_unminimized_and_aligned", allExternalWindowsReady(),
                   "All managed documents remain open at the common frame; selecting changes focus only.")
            geometryUnchanged = geometryUnchanged && candidates.enumerated().allSatisfy { position, candidate in
                guard let actual = store.backend.frame(of: candidate), let baseline = warmFrames[position] else { return false }
                return externalSameFrame(actual, baseline, tolerance: 1)
                    && store.backend.isMinimized(candidate) == warmMinimized[position]
            }
        }
        record("repeated_switches_preserve_all_geometry_and_minimized_flags", geometryUnchanged,
               "After each direct focus switch, every live AX frame stays within 1 point of its post-start baseline and every minimized flag is unchanged.")
        let afterWarmDiagnostics = store.backend.diagnostics
        record("warm_switches_do_not_call_geometry_or_minimize_apis",
               afterWarmDiagnostics.setFrameCalls == warmDiagnostics.setFrameCalls
                && afterWarmDiagnostics.setMinimizedCalls == warmDiagnostics.setMinimizedCalls
                && afterWarmDiagnostics.positionWrites == warmDiagnostics.positionWrites
                && afterWarmDiagnostics.sizeWrites == warmDiagnostics.sizeWrites
                && afterWarmDiagnostics.minimizedWrites == warmDiagnostics.minimizedWrites,
               "setFrameCalls \(warmDiagnostics.setFrameCalls)→\(afterWarmDiagnostics.setFrameCalls); setMinimizedCalls \(warmDiagnostics.setMinimizedCalls)→\(afterWarmDiagnostics.setMinimizedCalls); positionWrites \(warmDiagnostics.positionWrites)→\(afterWarmDiagnostics.positionWrites); sizeWrites \(warmDiagnostics.sizeWrites)→\(afterWarmDiagnostics.sizeWrites); minimizedWrites \(warmDiagnostics.minimizedWrites)→\(afterWarmDiagnostics.minimizedWrites); focusCalls \(warmDiagnostics.focusCalls)→\(afterWarmDiagnostics.focusCalls); warmFocusSuccesses \(warmDiagnostics.warmFocusSuccesses)→\(afterWarmDiagnostics.warmFocusSuccesses).")

        if store.isRunning, !store.isBusy, store.order.activeID == candidates[0].id,
           let normalFrame = store.backend.frame(of: candidates[0]) {
            store.toggleExpanded()
            let expandedExpected = store.mainAXFrame
            let expandedCorrect = await externalWait(timeout: 6) {
                !store.isBusy && store.expanded && candidates.allSatisfy { candidate in
                    store.backend.frame(of: candidate).map {
                        externalSameFrame($0, expandedExpected) && $0.width > normalFrame.width
                    } == true && store.backend.isMinimized(candidate) == false
                }
            }
            record("expanded_aligns_all_actual_frames", expandedCorrect, store.status)
            store.toggleExpanded()
            let normalCorrect = await externalWait(timeout: 6) {
                !store.isBusy && !store.expanded && candidates.allSatisfy { candidate in
                    store.backend.frame(of: candidate).map { externalSameFrame($0, normalFrame) } == true
                        && store.backend.isMinimized(candidate) == false
                }
            }
            record("expanded_restores_all_main_frames", normalCorrect, store.status)
        } else {
            record("expanded_aligns_all_actual_frames", false, "Workspace did not return to the first window in a usable state.")
        }
    }

    // stop() cancels any outstanding operation token even if startup has not yet
    // entered running state, so a timed-out start cannot mutate windows later.
    store.stop()
    await store.waitForRestoration()
    record("stop_clears_running_state", !store.isRunning && !store.isBusy && !store.expanded)
    let allRestored = await externalWait(timeout: 3) {
        zip(candidates, originals).allSatisfy { candidate, original in
            guard let actual = store.backend.frame(of: candidate), let frame = original.frame else { return false }
            let expected = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            return externalSameFrame(actual, expected, tolerance: 2)
                && store.backend.isMinimized(candidate) == original.minimized
        }
    }
    restored = candidates.map { externalState($0, backend: store.backend) }
    record("stop_restores_original_geometry_and_minimized_state", allRestored,
           "Each original AX frame restored within 2 points and original minimized flag restored exactly.")
    record("stop_keeps_fixture_documents_alive", candidates.allSatisfy { store.backend.isAlive($0) })
    record("recovery_journal_completed", store.pendingRecovery.isEmpty, store.status)
    if !allRestored && !store.pendingRecovery.isEmpty {
        // Only fixture records can exist because pristine startup was required.
        // Keep the failure above even if cleanup succeeds; never turn a failed
        // first restoration attempt into a passing integration result.
        store.recover()
        await store.waitForRestoration()
        record("cleanup_recovery_attempt", store.pendingRecovery.isEmpty, store.status)
        restored = candidates.map { externalState($0, backend: store.backend) }
    }
    if allRestored && store.pendingRecovery.isEmpty {
        func originalsStillRestored() -> Bool {
            zip(candidates, originals).allSatisfy { candidate, original in
                guard let actual = store.backend.frame(of:candidate), let frame = original.frame else { return false }
                return externalSameFrame(actual,CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height),tolerance:2)
                    && store.backend.isMinimized(candidate) == original.minimized
            }
        }
        store.start(); store.stop()
        await store.waitForRestoration()
        try? await Task.sleep(nanoseconds:350_000_000)
        record("cancel_start_does_not_write_or_move_later", !store.isRunning && !store.isBusy && originalsStillRestored() && store.pendingRecovery.isEmpty)
        store.start()
        let restarted = await externalWait(timeout:15) { !store.isBusy }
        record("restart_after_cancel", restarted && store.isRunning,store.status)
        if restarted && store.isRunning {
            let firstID = store.order.ids[1]
            let burstStarted = ProcessInfo.processInfo.systemUptime
            store.select(firstID)
            store.select(index:2)
            let burstSettled = await externalWait(timeout:6) { !store.isBusy }
            let burstFocused = burstSettled && store.order.activeID == firstID && externalFocusedWindowIs(candidates[1])
            if burstFocused { switchLatencies.append((ProcessInfo.processInfo.systemUptime - burstStarted) * 1_000) }
            record("busy_switch_input_is_not_queued", burstFocused)
            record("busy_switch_keeps_all_windows_ready", allExternalWindowsReady())
            let focusCallsBeforeCancellation = store.backend.diagnostics.focusCalls
            store.select(index:2)
            // Enter the direct AX handoff before its 15 ms focus verification
            // completes. This exercises cancellation in flight without relying
            // on an animation or geometry-settlement duration.
            try? await Task.sleep(nanoseconds:5_000_000)
            let focusHandoffStarted = store.backend.diagnostics.focusCalls > focusCallsBeforeCancellation
            let selectedWhenStopping = store.order.activeID
            store.stop(); await store.waitForRestoration()
            let focusedAfterRestoration = candidates.firstIndex { externalFocusedWindowIs($0) }
            try? await Task.sleep(nanoseconds:350_000_000)
            record("cancelled_external_focus_handoff_was_started", focusHandoffStarted,
                   "backend.focusCalls increased before stop(), so cancellation covers an entered AX handoff.")
            record("cancel_immediate_focus_handoff_has_no_late_mutation", !store.isRunning && !store.isBusy && store.order.activeID == selectedWhenStopping && originalsStillRestored())
            record("cancel_immediate_focus_handoff_has_no_late_focus", candidates.firstIndex { externalFocusedWindowIs($0) } == focusedAfterRestoration,
                   "The focused fixture identity (or absence of fixture focus) stays unchanged after restoration and a 350 ms observation interval.")
            record("cancelled_session_completes_recovery_journal", store.pendingRecovery.isEmpty,store.status)
            restored = candidates.map { externalState($0,backend:store.backend) }
        }
    }
    return finish()
}

@MainActor
private func externalState(_ candidate: WindowCandidate, backend: WindowBackend) -> ExternalWindowState {
    ExternalWindowState(id: candidate.id, title: candidate.title, pid: candidate.pid,
                        cgWindowID: candidate.cgWindowID, frame: backend.frame(of: candidate).map(ExternalFrame.init),
                        minimized: backend.isMinimized(candidate))
}

@MainActor
private func externalWait(timeout: TimeInterval, predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        do { try await Task.sleep(nanoseconds: 10_000_000) }
        catch { return false }
    }
    return predicate()
}

private func externalSameFrame(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}

@MainActor
private func externalFocusedWindowIs(_ candidate: WindowCandidate) -> Bool {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.2)
    var applicationValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &applicationValue) == .success,
          let applicationValue, CFGetTypeID(applicationValue) == AXUIElementGetTypeID() else { return false }
    let application = applicationValue as! AXUIElement
    var pid: pid_t = 0
    guard AXUIElementGetPid(application, &pid) == .success, pid == candidate.pid else { return false }
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
          let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
    return CFEqual(focusedValue, candidate.element)
}
