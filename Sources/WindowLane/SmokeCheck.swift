import AppKit
import Foundation
import WindowLaneCore

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
    let limitation = "App-owned NSWindow/NSTextView integration and isolated named-workspace storage only. Fractional layouts verify real window geometry and editor ownership, not delivery or acceptance of drag payloads. External application control, AX permission grants, ScreenCaptureKit capture, and global key delivery are not verified by this run."
    let completedAt: Date
    let passed: Bool
    let checks: [SmokeCheckResult]
    let originalFrames: [SmokeFrame]
    let restoredFrames: [SmokeFrame]
    let screenshotPath: String?
    let switchPerformance: SmokeSwitchPerformance
    let requestToFocusMilliseconds: [Double]
}

private struct SmokeSwitchPerformance: Encodable {
    let measurement = "Monotonic elapsed time from select() to completed presentation with confirmed native keyboard focus, including outgoing native snapshot preparation, focus handoff, page-turn animation when enabled, and diagnostic polling. Successful switches only; no fixed latency pass/fail budget."
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
func runSmokeCheck(store: WorkspaceStore, managerWindow: NSWindow, transition: PageTurnTransition) async -> Bool {
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
    var focusLatencies: [Double] = []
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
            switchPerformance: SmokeSwitchPerformance(switchLatencies),
            requestToFocusMilliseconds: focusLatencies
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

    // Exercise presentation fallbacks using only a generated in-memory image.
    // This never captures the user's screen or changes an accessibility setting.
    let fallbackFrame = CGRect(x: 0, y: 0, width: 96, height: 64)
    let fallbackImage = NSImage(size: fallbackFrame.size, flipped: false) { rect in
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        return true
    }
    let reducedTransition = PageTurnTransition(reduceMotion: { true })
    record("reduce_motion_bypasses_page_turn", !reducedTransition.prepare(image: fallbackImage, frame: fallbackFrame, direction: 1)
           && !reducedTransition.isVisible && !reducedTransition.isAnimating && reducedTransition.preparedCount == 0,
           "Injected Reduce Motion policy; no macOS preference was modified.")
    reducedTransition.cancel()
    let fallbackTransition = PageTurnTransition(reduceMotion: { false })
    let emptyBypassed = !fallbackTransition.prepare(image: NSImage(size: .zero), frame: fallbackFrame, direction: 1)
        && !fallbackTransition.isVisible && !fallbackTransition.isAnimating
    record("empty_snapshot_bypasses_page_turn", emptyBypassed)
    fallbackTransition.cancel()
    let mismatchFrame = CGRect(x: 0, y: 0, width: 192, height: 128)
    let mismatchBypassed = !fallbackTransition.prepare(image: fallbackImage, frame: mismatchFrame, direction: -1)
        && !fallbackTransition.isVisible && !fallbackTransition.isAnimating
    record("mismatched_snapshot_bypasses_page_turn", mismatchBypassed,
           "A 96 × 64 logical-point image must not be stretched into a 192 × 128 window.")
    fallbackTransition.cancel()

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
        if let latency = store.lastSwitchFocusMilliseconds { focusLatencies.append(latency) }
    }
    func direction(to index: Int) -> Int { index > store.activeIndex ? 1 : -1 }
    func recordPageTurn(_ name: String, preparedBefore: Int, completedBefore: Int, expectedDirection: Int, settled: Bool, reducedMotion: Bool) {
        let hidden = !transition.isVisible && !transition.isAnimating
        if reducedMotion {
            record("\(name)_reduce_motion_bypassed", settled && hidden
                   && transition.preparedCount == preparedBefore && transition.completedCount == completedBefore,
                   "System Reduce Motion was enabled; this check verifies bypass, not an animated presentation.")
        } else {
            record("\(name)_animation_completed", settled && hidden
                   && transition.preparedCount == preparedBefore + 1
                   && transition.completedCount == completedBefore + 1 && transition.lastDirection == expectedDirection,
                   "direction=\(String(describing: transition.lastDirection)), expected=\(expectedDirection); prepared \(preparedBefore)→\(transition.preparedCount); completed \(completedBefore)→\(transition.completedCount).")
        }
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

    var preparedBefore = transition.preparedCount
    var completedBefore = transition.completedCount
    var expectedDirection = direction(to: 0)
    var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var switchStarted = ProcessInfo.processInfo.systemUptime
    store.select(index: 0)
    let selectSettled = await smokeWaitUntilSettled(store)
    noteSwitchLatency(startedAt: switchStarted, destination: originalIDs[1], settled: selectSettled)
    record("select_settles", selectSettled, store.status)
    record("select_uses_reordered_identity", store.order.activeID == originalIDs[1])
    record("selected_window_key_and_editable", NSApp.keyWindow === windows[1] && windows[1].firstResponder === editors[1],
           smokeFocusDetail(expectedWindow: windows[1], expectedResponder: editors[1], activeID: store.order.activeID))
    record("switch_keeps_all_windows_ready", allManagedWindowsReady())
    recordPageTurn("backward_page_turn", preparedBefore: preparedBefore, completedBefore: completedBefore,
                   expectedDirection: expectedDirection, settled: selectSettled, reducedMotion: reducedMotion)

    preparedBefore = transition.preparedCount
    completedBefore = transition.completedCount
    expectedDirection = direction(to: store.activeIndex + 1)
    reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    switchStarted = ProcessInfo.processInfo.systemUptime
    store.step(1)
    let stepSettled = await smokeWaitUntilSettled(store)
    noteSwitchLatency(startedAt: switchStarted, destination: originalIDs[2], settled: stepSettled)
    record("step_settles", stepSettled, store.status)
    record("next_window_selected", store.order.activeID == originalIDs[2])
    recordPageTurn("forward_page_turn", preparedBefore: preparedBefore, completedBefore: completedBefore,
                   expectedDirection: expectedDirection, settled: stepSettled, reducedMotion: reducedMotion)
    record("page_turn_retains_target_keyboard_editor", NSApp.keyWindow === windows[2] && windows[2].firstResponder === editors[2],
           smokeFocusDetail(expectedWindow: windows[2], expectedResponder: editors[2], activeID: store.order.activeID))
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

    // Unlike the earlier immediate-cancel case, wait for an actually entered
    // animation so cancellation covers the visual awaiter and overlay teardown.
    store.start()
    let animationRestarted = await smokeWaitUntilSettled(store) && store.isRunning
    record("restart_for_animation_cancellation", animationRestarted, store.status)
    if animationRestarted, let destination = store.order.ids.first(where: { $0 != store.order.activeID }) {
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cancelledBefore = transition.cancelledCount
        let completedBeforeCancellation = transition.completedCount
        store.select(destination)
        if reducedMotion {
            let settled = await smokeWaitUntilSettled(store)
            record("animation_cancellation_reduce_motion_bypass", settled && !transition.isVisible && !transition.isAnimating,
                   "System Reduce Motion bypasses animation; active-animation cancellation was not exercised.")
        } else {
            let animationEntered = await smokeWait(timeout: 2) { transition.isAnimating && transition.isVisible }
            record("cancellation_enters_visible_page_turn", animationEntered,
                   "Polled renderer state; an arbitrary delay is not used as evidence that animation began.")
            let destinationWindow = store.entries[destination]?.native
            let destinationEditor = (destinationWindow?.contentView as? NSScrollView)?.documentView as? NSTextView
            record("visible_page_turn_keeps_real_keyboard_focus", animationEntered && store.order.activeID == destination
                   && NSApp.keyWindow === destinationWindow && destinationWindow?.firstResponder === destinationEditor,
                   smokeFocusDetail(expectedWindow: destinationWindow, expectedResponder: destinationEditor, activeID: store.order.activeID))
            let selectionAtStop = store.order.activeID
            store.stop()
            record("stop_immediately_removes_page_turn", !transition.isVisible && !transition.isAnimating
                   && (!animationEntered || transition.cancelledCount == cancelledBefore + 1))
            await store.waitForRestoration()
            let keyWindowAfterRestore = NSApp.keyWindow
            try? await Task.sleep(nanoseconds: 400_000_000)
            record("cancel_page_turn_has_no_late_mutation", !store.isRunning && !store.isBusy
                   && store.order.activeID == selectionAtStop && NSApp.keyWindow === keyWindowAfterRestore
                   && !transition.isVisible && !transition.isAnimating
                   && transition.completedCount == completedBeforeCancellation && windows.map(\.frame) == originals,
                   "Selection, keyboard focus, overlay visibility, completion count, and original frames remain unchanged after a 400 ms observation interval.")
            record("cancel_page_turn_preserves_documents", windows.allSatisfy { $0.isVisible && !$0.isMiniaturized }
                   && editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })
        }
    }
    store.stop(); await store.waitForRestoration()

    // Restore the fixture removed earlier without closing or recreating its
    // document. Three pages are needed to exercise both fractional pairs.
    if store.entries[originalIDs[1]] == nil {
        store.entries[originalIDs[1]] = ManagedWindow(native: windows[1], index: 1)
    }
    store.order = WorkspaceOrder(ids: originalIDs, activeID: originalIDs[0])
    store.pagePosition = 0
    func visibleNativeFramesMatch() -> Bool {
        store.visibleWindowIDs.allSatisfy { id in
            guard let window = store.entries[id]?.native else { return false }
            return window.isVisible && !window.isMiniaturized && smokeSameFrame(window.frame, store.frameForWindow(id))
        }
    }
    func splitEditorsAreReal() -> Bool {
        store.visibleWindowIDs.count == 2 && store.visibleWindowIDs.allSatisfy { id in
            guard let window = store.entries[id]?.native,
                  let editor = (window.contentView as? NSScrollView)?.documentView as? NSTextView else { return false }
            return editor.isEditable && editors.contains { $0 === editor } && window.isVisible
        }
    }
    func activeSplitEditorHasFocus() -> Bool {
        guard let active = store.active, store.visibleWindowIDs.contains(active.id), let window = active.native,
              let editor = (window.contentView as? NSScrollView)?.documentView as? NSTextView else { return false }
        return NSApp.keyWindow === window && window.firstResponder === editor
    }
    func bothPanesAreAboveOtherManagedWindows() -> Bool {
        let visible = store.visibleWindowIDs.compactMap { store.entries[$0]?.native }
        let windowNumbers = Set(windows.map(\.windowNumber))
        let serverWindows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let frontNumbers = serverWindows.compactMap { $0[kCGWindowNumber as String] as? Int }
            .filter { windowNumbers.contains($0) }.prefix(2)
        print("PANE_ORDER visible=\(visible.map(\.windowNumber)) server=\(Array(frontNumbers)) key=\(NSApp.keyWindow?.windowNumber ?? -1) appkit=\(NSApp.orderedWindows.filter { windowNumbers.contains($0.windowNumber) }.map(\.windowNumber))")
        return visible.count == 2 && frontNumbers.count == 2
            && visible.allSatisfy { frontNumbers.contains($0.windowNumber) }
    }
    let ratioBeforePresetTests = store.ratio
    store.start()
    let fractionalStarted = await smokeWaitUntilSettled(store) && store.isRunning
    record("fractional_layout_starts_three_existing_documents", fractionalStarted && store.ordered.count == 3, store.status)
    if fractionalStarted {
        store.commitContinuousPaging(position: 0.5)
        let halfSettled = await smokeWaitUntilSettled(store)
        let leftHalf = windows[0].frame
        let rightHalf = windows[1].frame
        record("half_page_preserves_fraction_after_release", halfSettled && store.isRunning && store.isSplit
               && abs(store.pagePosition - 0.5) < 0.0001, store.status)
        record("half_page_two_live_equal_nonoverlapping_frames", halfSettled && visibleNativeFramesMatch()
               && abs(leftHalf.width - rightHalf.width) <= 1 && leftHalf.maxX <= rightHalf.minX
               && smokeSameFrame(leftHalf, store.frameForWindow(originalIDs[0]))
               && smokeSameFrame(rightHalf, store.frameForWindow(originalIDs[1])),
               "Live NSWindow frames equal the requested two-pane layout; tolerance 1 point.")
        record("half_page_contains_original_native_editors", splitEditorsAreReal())
        record("half_page_active_editor_has_real_keyboard_focus", activeSplitEditorHasFocus(), smokeFocusDetail(expectedWindow: store.active?.native, expectedResponder: editors[store.activeIndex], activeID: store.order.activeID))
        record("half_page_both_panes_above_other_managed_documents", bothPanesAreAboveOtherManagedWindows(),
               "WindowServer front-to-back ordering confirms that an inactive managed document cannot cover either real pane; AppKit orderedWindows may cache an older list.")
        record("half_page_releases_snapshot_pointer_shield", !transition.isVisible && !transition.isAnimating,
               "No page snapshot remains above either real window after the fractional commit. Actual drag payload delivery is a separate UI check.")

        let testDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let isolatedPresetStorage = store.presets.url.standardizedFileURL.path.hasPrefix(testDirectory + "/")
        record("named_workspace_storage_is_isolated", isolatedPresetStorage,
               "Preset writes are allowed only in this diagnostic run's temporary storage, never the user's collection.")
        var savedPreset: WorkspacePreset?
        if isolatedPresetStorage {
            do {
                let name = "Half-page smoke \(UUID().uuidString.prefix(8))"
                try store.savePresetThrowing(name: name)
                savedPreset = store.selectedPresetID.flatMap { id in store.presets.items.first { $0.id == id } }
                record("named_workspace_saves_current_order_and_half_page", savedPreset.map {
                    $0.name == name && $0.windows.map(\.id) == store.order.ids
                        && abs($0.effectivePagePosition - 0.5) < 0.0001 && $0.activeSlot == store.activeIndex
                        && abs($0.mainRatio - store.ratio) < 0.0001
                } ?? false)
                if let saved = savedPreset {
                    let renamed = "Renamed \(name)"
                    try store.presets.rename(saved.id, to: renamed)
                    record("named_workspace_rename_keeps_identity", store.presets.items.first { $0.id == saved.id }?.name == renamed)
                    try store.savePresetThrowing(name: renamed, replacing: saved.id)
                    savedPreset = store.presets.items.first { $0.id == saved.id }
                    record("named_workspace_update_keeps_identity_and_creation_date", savedPreset.map {
                        $0.id == saved.id && $0.createdAt == saved.createdAt && abs($0.effectivePagePosition - 0.5) < 0.0001
                    } ?? false)
                    let reopened = WorkspacePresets(url: store.presets.url)
                    record("named_workspace_reload_preserves_saved_half_page", reopened.readError == nil
                           && reopened.items.first { $0.id == saved.id } == savedPreset)
                    let deleted = try store.presets.delete(saved.id)
                    record("named_workspace_delete_removes_only_preset", !store.presets.items.contains { $0.id == saved.id }
                           && windows.allSatisfy(\.isVisible) && store.isRunning)
                    try store.presets.restore(deleted)
                    record("named_workspace_delete_can_be_undone", store.presets.items.first { $0.id == saved.id } == deleted)
                }
            } catch { record("named_workspace_crud_completed", false, error.localizedDescription) }
        }

        let framesBeforeContinuousPreview = windows.map(\.frame)
        store.beginContinuousPaging()
        store.updateContinuousPaging(position: 1.25)
        record("continuous_preview_tracks_fraction_without_early_window_mutation", store.isBusy
               && abs(store.pagePosition - 1.25) < 0.0001 && windows.map(\.frame) == framesBeforeContinuousPreview,
               "Preview movement retains the real panes until the native geometry commit on release.")
        store.commitContinuousPaging(position: 1.25)
        let quarterSettled = await smokeWaitUntilSettled(store)
        record("quarter_page_preserves_fraction_and_live_pair", quarterSettled && store.isRunning && store.isSplit
               && abs(store.pagePosition - 1.25) < 0.0001 && store.visibleWindowIDs == [originalIDs[1], originalIDs[2]]
               && visibleNativeFramesMatch() && windows[1].frame.maxX <= windows[2].frame.minX,
               "After release, position 1.25 remains accepted and the second/third real windows stay side by side.")
        record("quarter_page_keeps_original_editors_and_drafts", splitEditorsAreReal()
               && editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })
        store.commitContinuousPaging(position: 2)
        let wholeSettled = await smokeWaitUntilSettled(store)
        record("whole_page_restores_all_windows_to_common_main_frame", wholeSettled && store.isRunning && !store.isSplit
               && abs(store.pagePosition - 2) < 0.0001 && allManagedWindowsReady(), store.status)
        store.stop(); await store.waitForRestoration()
        record("fractional_and_whole_layouts_restore_original_documents", !store.isRunning && !store.isBusy
               && windows.map(\.frame) == originals
               && editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })

        if let saved = savedPreset {
            store.move(originalIDs[0], to: 2)
            store.ratio = saved.mainRatio == 0.8 ? 0.9 : 0.8
            let reapplied = store.applyPreset(saved.id)
            record("named_workspace_apply_restores_order_ratio_and_fraction", reapplied
                   && store.order.ids == saved.windows.map(\.id) && abs(store.ratio - saved.mainRatio) < 0.0001
                   && abs(store.pagePosition - 0.5) < 0.0001 && store.selectedPresetID == saved.id, store.status)
            let reorderedName = "Reordered demo smoke \(UUID().uuidString.prefix(8))"
            store.move(originalIDs[0], to: 2)
            let reorderedIDs = store.order.ids
            do {
                try store.savePresetThrowing(name: reorderedName)
                let reorderedID = store.selectedPresetID
                store.move(originalIDs[0], to: 0)
                let appliedReordered = reorderedID.map { store.applyPreset($0) } ?? false
                record("reordered_demo_preset_restores_specific_document_identity", appliedReordered && store.order.ids == reorderedIDs
                       && originalIDs.enumerated().allSatisfy { store.entries[$0.element]?.native === windows[$0.offset] },
                       "Demo document identity is its fixture index, independent of the saved display order.")
                if let reorderedID { _ = try store.presets.delete(reorderedID) }
                _ = store.applyPreset(saved.id)
            } catch { record("reordered_demo_preset_check_completed", false, error.localizedDescription) }
            let orderBeforeMissing = store.order
            let entriesBeforeMissing = Set(store.entries.keys)
            let positionBeforeMissing = store.pagePosition
            let ratioBeforeMissing = store.ratio
            record("missing_workspace_does_not_replace_current_selection", !store.applyPreset(UUID())
                   && store.order == orderBeforeMissing && Set(store.entries.keys) == entriesBeforeMissing
                   && store.pagePosition == positionBeforeMissing && store.ratio == ratioBeforeMissing)
            do {
                let absent = try store.presets.save(name: "Unresolved smoke fixture", windows: [
                    WorkspaceWindowDescriptor(id: "missing-smoke-window", bundleIdentifier: "com.feizhang.windowlane.smoke.missing",
                                              appName: "Missing fixture", title: "Unopened smoke document")
                ])
                record("unresolved_saved_workspace_preserves_current_selection", !store.applyPreset(absent.id)
                       && store.order == orderBeforeMissing && Set(store.entries.keys) == entriesBeforeMissing
                       && store.pagePosition == positionBeforeMissing && store.ratio == ratioBeforeMissing,
                       "A missing saved window prevents replacing the current workspace; no application or document is reopened.")
                _ = try store.presets.delete(absent.id)
            } catch { record("unresolved_saved_workspace_check_completed", false, error.localizedDescription) }
            store.start()
            let savedRestarted = await smokeWaitUntilSettled(store) && store.isRunning
            record("saved_half_page_restarts_with_real_window_geometry", savedRestarted && store.isSplit
                   && abs(store.pagePosition - 0.5) < 0.0001 && visibleNativeFramesMatch() && splitEditorsAreReal(), store.status)
            record("saved_half_page_exposes_both_panes_above_remaining_documents", savedRestarted
                   && bothPanesAreAboveOtherManagedWindows(),
                   "Visible: \(store.visibleWindowIDs); front-to-back: \(NSApp.orderedWindows.filter { window in windows.contains { $0 === window } }.map(\.title))")
            if savedRestarted {
                let beforeCancel = windows.map(\.frame)
                store.beginContinuousPaging()
                store.updateContinuousPaging(position: 0.75)
                store.cancelContinuousPaging()
                record("cancel_continuous_preview_retains_accepted_fraction_and_geometry", !store.isBusy
                       && abs(store.pagePosition - 0.5) < 0.0001 && windows.map(\.frame) == beforeCancel)
            }
            store.stop(); await store.waitForRestoration()
            record("saved_half_page_exit_restores_original_geometry", windows.map(\.frame) == originals && !store.isBusy)
            _ = try? store.presets.delete(saved.id)
        }
    }
    // Simulate Obsidian/Electron accepting AX resize requests while enforcing
    // a larger native minimum than the generic 320-point pane estimate.
    store.start()
    let sizingStarted = await smokeWaitUntilSettled(store) && store.isRunning
    record("minimum_width_fixture_starts", sizingStarted, store.status)
    if sizingStarted, let constrained = windows[1] as? SizingFixtureWindow,
       let firstConstrained = windows[0] as? SizingFixtureWindow {
        let requested = BookPageLayout(visibleFrame: store.screen.visibleFrame, mainRatio: store.ratio, position: 0.08, count: 3)
        let learnedMinimum = max(500, requested.bookFrame.width * 0.40)
        constrained.imposedMinimumWidth = learnedMinimum
        store.commitContinuousPaging(position: 0.08)
        let adapted = await smokeWaitUntilSettled(store)
        record("application_minimum_width_adapts_without_exiting_workspace", adapted && store.isRunning && store.isSplit
               && abs(store.pagePosition - 0.08) < 0.0001 && windows[1].frame.width >= learnedMinimum
               && windows[0].frame.maxX <= windows[1].frame.minX && !store.isError, store.status)
        record("adapted_panes_match_real_geometry_and_are_exposed", visibleNativeFramesMatch()
               && bothPanesAreAboveOtherManagedWindows() && activeSplitEditorHasFocus())
        // Return to a single accepted page, then force two incompatible minima.
        constrained.imposedMinimumWidth = 0
        store.commitContinuousPaging(position: 0)
        _ = await smokeWaitUntilSettled(store)
        let accepted = windows.map(\.frame)
        let originalValues = store.ordered.map(\.originalFrame)
        firstConstrained.imposedMinimumWidth = requested.bookFrame.width * 0.60
        constrained.imposedMinimumWidth = requested.bookFrame.width * 0.60
        store.commitContinuousPaging(position: 0.5)
        let rejected = await smokeWaitUntilSettled(store)
        record("impossible_split_rolls_back_and_keeps_workspace_running", rejected && store.isRunning && store.isError
               && !store.isSplit && store.pagePosition == 0 && windows.map(\.frame) == accepted, store.status)
        record("size_rejection_preserves_original_recovery_frames_and_documents", store.ordered.map(\.originalFrame) == originalValues
               && editors.indices.allSatisfy { editors[$0].string == drafts[$0] && editors[$0].selectedRange() == selections[$0] })
        firstConstrained.imposedMinimumWidth = 0; constrained.imposedMinimumWidth = 0
        store.select(index: 2)
        let switchedAfterRejection = await smokeWaitUntilSettled(store)
        record("whole_page_switch_works_after_size_rejection", switchedAfterRejection && store.isRunning
               && store.active?.id == originalIDs[2] && NSApp.keyWindow === windows[2], store.status)
    }
    store.stop(); await store.waitForRestoration()
    let normalMinimums = windows.map(\.minSize)
    let incompatibleWidth = store.bookLayout.bookFrame.width * 0.60
    windows[0].minSize.width = incompatibleWidth
    windows[1].minSize.width = incompatibleWidth
    store.order.select(originalIDs[0])
    store.pagePosition = 0.5
    store.start()
    let fallbackStarted = await smokeWaitUntilSettled(store)
    record("saved_split_with_incompatible_minimums_starts_as_single_page", fallbackStarted && store.isRunning
           && !store.isSplit && store.pagePosition == 0 && allManagedWindowsReady(), store.status)
    for index in windows.indices { windows[index].minSize = normalMinimums[index] }
    store.stop(); await store.waitForRestoration()
    record("minimum_width_recovery_and_saved_split_fallback_restore_original_frames", windows.map(\.frame) == originals
           && !store.isBusy && !store.isRunning)
    store.ratio = ratioBeforePresetTests
    restored = windows.map(\.frame)

    // These documents were created only for this explicitly requested smoke run.
    store.fixtures.close()
    return finish()
}

@MainActor
private func smokeWait(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
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
