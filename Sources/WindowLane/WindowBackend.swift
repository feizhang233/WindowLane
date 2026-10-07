import AppKit
import ApplicationServices
import ScreenCaptureKit
import WindowLaneCore
import OSLog

/// A reference to a particular native window, not to an application or a title.
/// `frame` is a discovery snapshot in AX global coordinates (origin at top left).
struct WindowCandidate: Identifiable {
    let id: String
    let title: String
    let appName: String
    let pid: pid_t
    let application: NSRunningApplication
    let bundleIdentifier: String?
    let launchDate: Date?
    let icon: NSImage?
    let element: AXUIElement
    let cgWindowID: CGWindowID?
    let frame: CGRect
    let isMinimized: Bool
}

enum RecoveryLookup {
    case found(WindowCandidate)
    case processEnded
    case unavailable(String)
}

/// In-memory counters for comparing a prepared workspace before/after a switch.
/// Write counters count actual AX setter attempts, including bounded retries.
struct WindowBackendDiagnostics {
    var setFrameCalls = 0
    var setMinimizedCalls = 0
    var positionWrites = 0
    var sizeWrites = 0
    var minimizedWrites = 0
    var focusCalls = 0
    var focusSuccesses = 0
    var warmFocusSuccesses = 0
    var activationRequests = 0
    var lastFocusMilliseconds: Double = 0
}

enum WindowBackendError: LocalizedError {
    case permissionRequired
    case windowUnavailable
    case invalidFrame
    case fullscreenWindow
    case failed(String, AXError)
    case activationFailed
    case minimumWidth(CGFloat)
    case frameNotSettled(expected: CGRect, actual: CGRect?)
    case minimizedNotSettled(expected: Bool, actual: Bool?)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "請先在系統設定允許 WindowLane 使用輔助使用功能。"
        case .windowUnavailable: return "這個視窗已關閉，或目前無法控制。"
        case .invalidFrame: return "無法使用這個視窗位置或尺寸。"
        case .fullscreenWindow: return "請先退出這個視窗的 macOS 全螢幕模式，再重試排列或復原。"
        case .failed(let action, let error): return "\(action)未完成（輔助使用錯誤 \(error.rawValue)）。應用可能暫時忙碌或不支援此操作。"
        case .activationFailed: return "無法將這個應用帶到前景。"
        case .minimumWidth(let width): return "此應用的視窗寬度至少需要 \(Int(width.rounded(.up))) 點。"
        case .frameNotSettled: return "視窗尺寸或位置尚未到位，可能受應用限制。請重試復原。"
        case .minimizedNotSettled: return "視窗收起或恢復尚未完成。請重試。"
        }
    }

    var failureReason: String? {
        switch self {
        case .frameNotSettled(let expected, let actual):
            return "Expected AX frame: \(expected); last actual AX frame: \(String(describing: actual))."
        case .minimizedNotSettled(let expected, let actual):
            return "Expected AX minimized: \(expected); last actual AX minimized: \(String(describing: actual))."
        default: return nil
        }
    }
}

@MainActor
final class WindowBackend {
    private struct Identity {
        let pid: pid_t
        let application: NSRunningApplication
        let element: AXUIElement
        let id: String
    }

    private var identities: [Identity] = []
    private var lastExternalPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private(set) var diagnostics = WindowBackendDiagnostics()
    private let logger = Logger(subsystem: "com.feizhang.windowlane", category: "geometry")

    var isTrusted: Bool { AXIsProcessTrusted() }

    init() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID {
            lastExternalPID = app.processIdentifier
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, pid != self.ownPID, app.activationPolicy == .regular else { return }
                self.lastExternalPID = pid
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// This is intentionally called only by an explicit permission button.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func listWindows() -> [WindowCandidate] {
        guard isTrusted else { return [] }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ownPID && !$0.isTerminated && $0.activationPolicy == .regular
        }
        identities.removeAll { identity in
            !applications.contains { identity.application.isEqual($0) }
        }
        let windowInfo = WindowMatching.windowInfo()
        return applications.flatMap { application in
            let appElement = makeAppElement(application.processIdentifier)
            guard let windows = AXRead.elements(appElement, kAXWindowsAttribute) else { return [WindowCandidate]() }
            return windows.compactMap { makeCandidate($0, application: application, info: windowInfo) }
        }.sorted {
            let comparison = $0.appName.localizedStandardCompare($1.appName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            let titleComparison = $0.title.localizedStandardCompare($1.title)
            return titleComparison == .orderedSame ? $0.id < $1.id : titleComparison == .orderedAscending
        }
    }

    /// Recovery must not depend on the stricter eligibility checks used when
    /// adding new windows. Never replace a lost identity with a title match.
    func recoveryCandidate(for record: RecoveryRecord) async -> RecoveryLookup {
        func unavailable(_ code: String, _ message: String) -> RecoveryLookup {
            print("WINDOWLANE_RECOVERY_LOOKUP pid=\(record.pid) reason=\(code)")
            return .unavailable(message)
        }
        guard !Task.isCancelled else { return unavailable("cancelled", "復原已中止，記錄仍保留。") }
        guard isTrusted else { return unavailable("permission", "請允許輔助使用權限後重試復原。") }
        guard record.pid != ownPID else { return unavailable("own_process", "無法確認原視窗的應用身分，記錄仍保留。") }
        guard let application = NSRunningApplication(processIdentifier: record.pid), !application.isTerminated else {
            return .processEnded
        }
        guard let bundleID = record.bundleID else { return unavailable("bundle_identity_unavailable", "缺少原應用的身分資料，記錄仍保留。") }
        guard let actualBundleID = application.bundleIdentifier, !actualBundleID.isEmpty else {
            return unavailable("current_bundle_identity_unavailable", "原應用的身分暫時無法讀取，記錄仍保留。")
        }
        guard actualBundleID == bundleID else { return .processEnded }
        if let expectedLaunch = record.launchTime, let actualLaunch = application.launchDate?.timeIntervalSince1970 {
            guard actualLaunch == expectedLaunch else {
                print("WINDOWLANE_RECOVERY_LOOKUP pid=\(record.pid) reason=launch_changed expected=\(expectedLaunch) actual=\(actualLaunch)")
                return .processEnded
            }
        } else {
            return unavailable("launch_identity_unavailable", "無法確認原應用的啟動身分，記錄仍保留。")
        }

        let appElement = makeAppElement(record.pid)
        var rawWindows: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard windowsError == .success else {
            return unavailable("windows_error_\(windowsError.rawValue)", "原應用暫時無法提供視窗清單，請稍後重試復原。")
        }
        guard let rawWindows, CFGetTypeID(rawWindows) == CFArrayGetTypeID(),
              let rawArray = rawWindows as? [AnyObject],
              rawArray.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            return unavailable("windows_invalid_type", "原應用回傳的視窗清單無法辨識，記錄仍保留。")
        }
        let windows = rawArray.map { $0 as! AXUIElement }
        guard !windows.isEmpty else {
            return unavailable("windows_empty", "原應用目前沒有提供可確認的視窗，記錄仍保留。")
        }

        let known = identities.first {
            $0.id == record.sessionID && $0.pid == record.pid && $0.application.isEqual(application)
        }
        let sameIdentity = known.map { identity in windows.filter { CFEqual($0, identity.element) } } ?? []
        guard sameIdentity.count <= 1 else {
            return unavailable("session_matches_\(sameIdentity.count)", "原視窗身分有多個對應，記錄仍保留。")
        }
        if let element = sameIdentity.first {
            await Task.yield()
            guard !Task.isCancelled, isTrusted else { return unavailable("interrupted", "復原已中止，記錄仍保留。") }
            guard !application.isTerminated,
                  let current = NSRunningApplication(processIdentifier: record.pid), application.isEqual(current) else { return .processEnded }
            guard let frame = recoveryFrame(element, pid: record.pid, index: 0) else {
                return unavailable("session_frame_unavailable", "原視窗的位置暫時無法讀取，請稍後重試復原。")
            }
            let confirmedID = record.windowID.flatMap { id -> CGWindowID? in
                guard let serverFrame = WindowMatching.frame(windowID: id, pid: record.pid),
                      WindowMatching.close(serverFrame, frame) else { return nil }
                return id
            }
            return .found(makeRecoveryCandidate(element, application: application, record: record, frame: frame, windowID: confirmedID))
        }

        guard let windowID = record.windowID else {
            return unavailable("original_cg_id_missing", "缺少原視窗的系統識別碼，無法安全自動復原。")
        }
        guard let windowInfo = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] else {
            return unavailable("windowserver_unavailable", "暫時無法讀取系統視窗資料，記錄仍保留。")
        }
        let serverMatches = windowInfo.filter {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == record.pid
        }
        guard serverMatches.count == 1,
              let bounds = serverMatches[0][kCGWindowBounds as String] as? [String: Any],
              let serverFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              serverFrame.origin.x.isFinite, serverFrame.origin.y.isFinite,
              serverFrame.width.isFinite, serverFrame.height.isFinite,
              serverFrame.width > 0, serverFrame.height > 0 else {
            return unavailable("original_cg_matches_\(serverMatches.count)", "系統暫時找不到原視窗的完整身分，記錄仍保留。")
        }

        var matches: [(element: AXUIElement, frame: CGRect)] = []
        var unreadable = 0
        for (index, element) in windows.enumerated() {
            await Task.yield()
            guard !Task.isCancelled, isTrusted else { return unavailable("interrupted", "復原已中止，記錄仍保留。") }
            guard !application.isTerminated,
                  let current = NSRunningApplication(processIdentifier: record.pid), application.isEqual(current) else { return .processEnded }
            guard let frame = recoveryFrame(element, pid: record.pid, index: index) else {
                unreadable += 1
                continue
            }
            if WindowMatching.close(frame, serverFrame) { matches.append((element, frame)) }
        }
        print("WINDOWLANE_RECOVERY_LOOKUP pid=\(record.pid) cgID=\(windowID) cgFrame=\(serverFrame) axCount=\(windows.count) unreadable=\(unreadable) matches=\(matches.count)")
        guard unreadable == 0 else {
            return unavailable("incomplete_ax_frames", "部分視窗位置暫時無法讀取，尚不能確認唯一的原視窗。")
        }
        guard matches.count == 1, let match = matches.first else {
            return unavailable("geometry_matches_\(matches.count)", "原視窗尚無唯一的系統身分對應，記錄仍保留。")
        }
        // An app can animate or close a window while this async scan yields.
        // Recheck both identities' geometry immediately before returning it.
        guard !Task.isCancelled, isTrusted else { return unavailable("interrupted", "復原已中止，記錄仍保留。") }
        guard !application.isTerminated,
              let current = NSRunningApplication(processIdentifier: record.pid), application.isEqual(current) else { return .processEnded }
        guard let finalServerFrame = WindowMatching.frame(windowID: windowID, pid: record.pid),
              WindowMatching.close(finalServerFrame, serverFrame),
              let finalFrame = recoveryFrame(match.element, pid: record.pid, index: -1),
              WindowMatching.close(finalFrame, finalServerFrame) else {
            return unavailable("geometry_changed", "原視窗仍在移動或暫時無法確認，請稍後重試復原。")
        }
        return .found(makeRecoveryCandidate(match.element, application: application, record: record, frame: finalFrame, windowID: windowID))
    }

    /// Opening WindowLane itself does not replace the remembered external target.
    func focusedWindow() -> WindowCandidate? {
        guard isTrusted else { return nil }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID, frontmost.activationPolicy == .regular {
            lastExternalPID = frontmost.processIdentifier
        }
        guard let pid = lastExternalPID,
              let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return nil }
        let appElement = makeAppElement(pid)
        guard let window = AXRead.element(appElement, kAXFocusedWindowAttribute)
                ?? AXRead.element(appElement, kAXMainWindowAttribute) else { return nil }
        return makeCandidate(window, application: application, info: WindowMatching.windowInfo())
    }

    /// A quick, fail-closed gesture gate. A sibling window or modal sheet must
    /// keep its own scroll events even when it belongs to the managed app.
    func isFocused(_ window: WindowCandidate) -> Bool {
        guard isTrusted, !window.application.isTerminated,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated, frontmost.processIdentifier == window.pid,
              window.application.isEqual(frontmost) else { return false }
        let appElement = AXUIElementCreateApplication(window.pid)
        guard AXUIElementSetMessagingTimeout(appElement, 0.075) == .success,
              let focused = AXRead.element(appElement, kAXFocusedWindowAttribute),
              CFEqual(focused, window.element) else { return false }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == window.pid,
              AXUIElementSetMessagingTimeout(focused, 0.05) == .success else { return false }
        defer { AXUIElementSetMessagingTimeout(focused, 0.3) }

        // These optional attributes are absent in some apps. An unsupported
        // attribute is different from a timed-out or invalid AX reference.
        var modal: CFTypeRef?
        let modalResult = AXUIElementCopyAttributeValue(focused, kAXModalAttribute as CFString, &modal)
        if modalResult == .success {
            guard let modal, CFGetTypeID(modal) == CFBooleanGetTypeID(),
                  !CFEqual(modal, kCFBooleanTrue) else { return false }
        } else if modalResult != .attributeUnsupported && modalResult != .noValue {
            return false
        }
        var sheets: CFTypeRef?
        let sheetsResult = AXUIElementCopyAttributeValue(focused, "AXSheets" as CFString, &sheets)
        if sheetsResult == .success {
            guard let sheets, CFGetTypeID(sheets) == CFArrayGetTypeID(),
                  let array = sheets as? [AnyObject], array.isEmpty else { return false }
        } else if sheetsResult != .attributeUnsupported && sheetsResult != .noValue {
            return false
        }
        guard let stillFrontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return !stillFrontmost.isTerminated && stillFrontmost.processIdentifier == window.pid
            && window.application.isEqual(stillFrontmost)
    }

    func frame(of window: WindowCandidate) -> CGRect? {
        guard isTrusted, isAlive(window) else { return nil }
        return AXRead.frame(window.element)
    }

    func isAlive(_ window: WindowCandidate) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated,
              !window.application.isTerminated, window.application.isEqual(app) else { return false }
        // Sleep/resume can invalidate an AX reference while its native window
        // remains open. WindowServer enumeration may also omit unavailable or
        // minimized windows, so neither failure proves closure. Only process
        // termination discards recovery eligibility; mutations still surface
        // actual AX errors. A closed window in a live app may require removal.
        // Never rebind an invalid reference using a possibly duplicated title.
        return true
    }

    /// Accepted AX writes may be applied later by the target application. Return
    /// only after observing the requested geometry; limits/timeouts remain errors.
    func setFrame(_ frame: CGRect, for window: WindowCandidate, isCancelled: () -> Bool = { false }) async throws {
        diagnostics.setFrameCalls += 1
        try requireLive(window, isCancelled: isCancelled)
        AXUIElementSetMessagingTimeout(window.element, 1.2)
        defer { AXUIElementSetMessagingTimeout(window.element, 0.3) }
        guard AXRead.bool(window.element, "AXFullScreen") != true else { throw WindowBackendError.fullscreenWindow }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { throw WindowBackendError.invalidFrame }
        var size = frame.size
        var position = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else { throw WindowBackendError.invalidFrame }

        guard var current = AXRead.frame(window.element) else { throw WindowBackendError.windowUnavailable }
        func needsSize(_ actual: CGSize, _ expected: CGSize) -> Bool {
            abs(actual.width - expected.width) > 1 || abs(actual.height - expected.height) > 1
        }
        func needsPosition(_ actual: CGPoint, _ expected: CGPoint) -> Bool {
            abs(actual.x - expected.x) > 1 || abs(actual.y - expected.y) > 1
        }
        func readCurrent() throws -> CGRect {
            try requireLive(window, isCancelled: isCancelled)
            guard let actual = AXRead.frame(window.element) else { throw WindowBackendError.windowUnavailable }
            return actual
        }

        // A previously dragged window may extend beyond the display. Resizing
        // at that final origin can clip its original size to the screen edge.
        // Grow at an in-bounds origin first, then restore the exact original one.
        // Already fitting frames and size changes that only shrink keep the
        // existing path. Never reduce an original size to make staging possible.
        var resizeOrigin = frame.origin
        if frame.width > current.width + 1 || frame.height > current.height + 1,
           let primaryHeight = NSScreen.screens.first?.frame.height {
            let targetAppKit = WorkspaceLayout.appKitFrame(fromAccessibility: frame, primaryScreenHeight: primaryHeight)
            let overlaps = NSScreen.screens.compactMap { screen -> (screen: NSScreen, area: CGFloat)? in
                let intersection = screen.frame.intersection(targetAppKit)
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
                return (screen, intersection.width * intersection.height)
            }
            if let largest = overlaps.map({ $0.area }).max() {
                let destinations = overlaps.filter { $0.area == largest }
                if destinations.count == 1, let destination = destinations.first {
                    let visibleAX = WorkspaceLayout.accessibilityFrame(
                        fromAppKit: destination.screen.visibleFrame, primaryScreenHeight: primaryHeight)
                    resizeOrigin = WindowRestorationGeometry.stagingOrigin(for: frame, visibleFrame: visibleAX) ?? frame.origin
                }
            }
        }
        var resizePosition = resizeOrigin
        guard let resizePositionValue = AXValueCreate(.cgPoint, &resizePosition) else { throw WindowBackendError.invalidFrame }

        // Shrink before moving so the window fits on a smaller destination. Grow
        // only after moving: resizing at the previous x/y can be screen-clamped.
        // Every changed stage settles before the next AX write to avoid AppKit's
        // independently animated size/position updates overwriting each other.
        var intermediateSize = CGSize(width: min(current.width, frame.width), height: min(current.height, frame.height))
        if needsSize(current.size, intermediateSize) {
            guard let intermediateValue = AXValueCreate(.cgSize, &intermediateSize) else { throw WindowBackendError.invalidFrame }
            try await write(window.element, kAXSizeAttribute, intermediateValue, action: "調整視窗大小", isCancelled: isCancelled)
            try await waitForFrame(CGRect(origin: current.origin, size: intermediateSize), window: window, sizeOnly: true, isCancelled: isCancelled)
            current = try readCurrent()
        }
        if needsPosition(current.origin, resizeOrigin) {
            try await write(window.element, kAXPositionAttribute, resizePositionValue, action: "移動視窗", isCancelled: isCancelled)
            try await waitForFrame(CGRect(origin: resizeOrigin, size: current.size), window: window, isCancelled: isCancelled)
            current = try readCurrent()
        }
        if needsSize(current.size, frame.size) {
            try await write(window.element, kAXSizeAttribute, sizeValue, action: "調整視窗大小", isCancelled: isCancelled)
            try await waitForFrame(frame, window: window, sizeOnly: true, isCancelled: isCancelled)
            current = try readCurrent()
        }
        if needsPosition(current.origin, frame.origin) {
            try await write(window.element, kAXPositionAttribute, positionValue, action: "移動視窗", isCancelled: isCancelled)
        }
        try await waitForFrame(frame, window: window, isCancelled: isCancelled)
    }

    func setMinimized(_ minimized: Bool, for window: WindowCandidate, isCancelled: () -> Bool = { false }) async throws {
        diagnostics.setMinimizedCalls += 1
        try requireLive(window, isCancelled: isCancelled)
        AXUIElementSetMessagingTimeout(window.element, 1.2)
        defer { AXUIElementSetMessagingTimeout(window.element, 0.3) }
        if isMinimized(window) == minimized {
            try requireLive(window, isCancelled: isCancelled)
            return
        }
        try await write(window.element, kAXMinimizedAttribute,
                        minimized ? kCFBooleanTrue : kCFBooleanFalse, action: minimized ? "收起視窗" : "恢復視窗", isCancelled: isCancelled)
        try await waitForMinimized(minimized, window: window, isCancelled: isCancelled)
    }

    func isMinimized(_ window: WindowCandidate) -> Bool? {
        guard isTrusted, isAlive(window) else { return nil }
        return AXRead.bool(window.element, kAXMinimizedAttribute)
    }

    /// Keep both panes visible while macOS continues the original drag session.
    /// This deliberately requests no app activation or keyboard-focus change.
    func raiseForInteraction(_ window: WindowCandidate) throws {
        guard isTrusted, isAlive(window) else { throw WindowBackendError.windowUnavailable }
        let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        guard result == .success else { throw WindowBackendError.failed("顯示並排視窗", result) }
    }

    func focus(_ window: WindowCandidate, isCancelled: () -> Bool = { false }) async throws {
        diagnostics.focusCalls += 1
        let started = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer {
            diagnostics.lastFocusMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            if succeeded { diagnostics.focusSuccesses += 1 }
        }
        try requireLive(window, isCancelled: isCancelled)
        if isMinimized(window) == true { try await setMinimized(false, for: window, isCancelled: isCancelled) }
        try requireLive(window, isCancelled: isCancelled)
        AXUIElementSetMessagingTimeout(window.element, 0.3)
        defer { AXUIElementSetMessagingTimeout(window.element, 0.3) }
        guard let application = NSRunningApplication(processIdentifier: window.pid) else {
            throw WindowBackendError.activationFailed
        }
        let appElement = makeAppElement(window.pid)
        defer { AXUIElementSetMessagingTimeout(appElement, 0.3) }
        var lastAXFailure: String?
        func attempt(_ operation: () async throws -> Void) async throws {
            try requireLive(window, isCancelled: isCancelled)
            do { try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch { lastAXFailure = error.localizedDescription }
        }

        // Prepared same-app windows need neither app reactivation nor geometry
        // changes. Try their normal main/raise handoff first; unsupported or
        // incomplete handoffs still go through the full fallback below.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           application.isEqual(frontmost) {
            let alreadyFocused = AXRead.element(appElement, kAXFocusedWindowAttribute)
                .map { CFEqual($0, window.element) } ?? false
            if !alreadyFocused {
                try await attempt { try await write(window.element, kAXMainAttribute, kCFBooleanTrue, action: "選取視窗", isCancelled: isCancelled) }
                try await attempt { try await raise(window.element, application: appElement, isCancelled: isCancelled) }
            }
            do {
                try await waitForFocus(window, timeout: 0.12, logFailure: false, isCancelled: isCancelled)
                succeeded = true
                diagnostics.warmFocusSuccesses += 1
                lastExternalPID = window.pid
                return
            } catch is CancellationError { throw CancellationError() }
            catch { lastAXFailure = error.localizedDescription }
        }

        try requireLive(window, isCancelled: isCancelled)
        AXUIElementSetMessagingTimeout(window.element, 1.2)
        AXUIElementSetMessagingTimeout(appElement, 1.2)
        let alreadyFrontmost = NSWorkspace.shared.frontmostApplication.map { application.isEqual($0) } ?? false
        var activationAccepted: Bool?
        if !alreadyFrontmost {
            diagnostics.activationRequests += 1
            if NSApp.isActive {
                NSApp.yieldActivation(to: application)
                activationAccepted = application.activate(from: .current, options: [])
            } else {
                activationAccepted = application.activate(options: [])
            }
        }
        // AppKit may reject an activation request during an inter-app handoff.
        // Use the supported AX focus operations, then judge the actual result.
        if !alreadyFrontmost, AXRead.isSettable(appElement, kAXFrontmostAttribute) {
            try await attempt { try await write(appElement, kAXFrontmostAttribute, kCFBooleanTrue, action: "切換前景應用", isCancelled: isCancelled) }
        }
        if AXRead.isSettable(window.element, kAXMainAttribute) {
            try await attempt { try await write(window.element, kAXMainAttribute, kCFBooleanTrue, action: "選取視窗", isCancelled: isCancelled) }
        }
        try await attempt { try await raise(window.element, application: appElement, isCancelled: isCancelled) }
        if AXRead.isSettable(appElement, kAXFocusedWindowAttribute) {
            try await attempt { try await write(appElement, kAXFocusedWindowAttribute, window.element, action: "切換輸入焦點", isCancelled: isCancelled) }
        }
        do { try await waitForFocus(window, isCancelled: isCancelled) }
        catch is CancellationError { throw CancellationError() }
        catch {
            print("WINDOWLANE_AX_FOCUS_FAILED activationAccepted=\(String(describing: activationAccepted)) lastAXFailure=\(lastAXFailure ?? "none")")
            throw error
        }
        succeeded = true
        lastExternalPID = window.pid
    }

    private func makeAppElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        // An unresponsive app should not stall the launcher for the default timeout.
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    private func recoveryFrame(_ element: AXUIElement, pid: pid_t, index: Int) -> CGRect? {
        guard AXUIElementSetMessagingTimeout(element, 0.15) == .success else { return nil }
        defer { AXUIElementSetMessagingTimeout(element, 0.3) }
        var actualPID: pid_t = 0
        let pidError = AXUIElementGetPid(element, &actualPID)
        guard pidError == .success, actualPID == pid else {
            print("WINDOWLANE_RECOVERY_AX pid=\(pid) index=\(index) pidError=\(pidError.rawValue) actualPID=\(actualPID)")
            return nil
        }
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var result: CGRect?
        if positionError == .success, sizeError == .success,
           let positionRef, let sizeRef, CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            let positionValue = positionRef as! AXValue, sizeValue = sizeRef as! AXValue
            var position = CGPoint.zero, size = CGSize.zero
            if AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
               AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size),
               position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
               size.width > 0, size.height > 0 { result = CGRect(origin: position, size: size) }
        }
        print("WINDOWLANE_RECOVERY_AX pid=\(pid) index=\(index) positionError=\(positionError.rawValue) sizeError=\(sizeError.rawValue) frame=\(String(describing: result))")
        return result
    }

    private func makeRecoveryCandidate(_ element: AXUIElement, application: NSRunningApplication,
                                       record: RecoveryRecord, frame: CGRect, windowID: CGWindowID?) -> WindowCandidate {
        let id: String
        if let known = identities.first(where: { $0.application.isEqual(application) && CFEqual($0.element, element) }) {
            id = known.id
        } else {
            id = UUID().uuidString
            identities.append(Identity(pid: record.pid, application: application, element: element, id: id))
        }
        return WindowCandidate(
            id: id, title: record.title, appName: application.localizedName ?? "應用程式",
            pid: record.pid, application: application, bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate, icon: application.icon, element: element,
            cgWindowID: windowID, frame: frame, isMinimized: AXRead.bool(element, kAXMinimizedAttribute) ?? record.minimized
        )
    }

    private func makeCandidate(_ element: AXUIElement, application: NSRunningApplication,
                               info: [[String: Any]]) -> WindowCandidate? {
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard AXRead.string(element, kAXRoleAttribute) == kAXWindowRole as String,
              AXRead.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              AXRead.bool(element, "AXFullScreen") != true,
              AXRead.isSettable(element, kAXPositionAttribute),
              AXRead.isSettable(element, kAXSizeAttribute),
              let frame = AXRead.frame(element), frame.width > 80, frame.height > 60 else { return nil }
        let pid = application.processIdentifier
        let id: String
        if let known = identities.first(where: { $0.application.isEqual(application) && CFEqual($0.element, element) }) {
            id = known.id
        } else {
            id = UUID().uuidString
            identities.append(Identity(pid: pid, application: application, element: element, id: id))
        }
        let rawTitle = AXRead.string(element, kAXTitleAttribute) ?? ""
        let appName = application.localizedName ?? "應用程式"
        return WindowCandidate(
            id: id, title: rawTitle.isEmpty ? "未命名視窗" : rawTitle,
            appName: appName, pid: pid, application: application,
            bundleIdentifier: application.bundleIdentifier, launchDate: application.launchDate,
            icon: application.icon, element: element,
            cgWindowID: WindowMatching.uniqueID(pid: pid, title: rawTitle, frame: frame, info: info),
            frame: frame, isMinimized: AXRead.bool(element, kAXMinimizedAttribute) ?? false
        )
    }

    private func checkCancellation(_ isCancelled: () -> Bool) throws {
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
    }

    private func requireLive(_ window: WindowCandidate, isCancelled: () -> Bool = { false }) throws {
        try checkCancellation(isCancelled)
        guard isTrusted else { throw WindowBackendError.permissionRequired }
        guard isAlive(window) else { throw WindowBackendError.windowUnavailable }
    }

    private func waitForFocus(_ window: WindowCandidate, timeout: TimeInterval = 0.8,
                              logFailure: Bool = true, isCancelled: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let system = AXUIElementCreateSystemWide()
        // A timeout on the system-wide object is process-local. Reset its global
        // default afterwards; existing window/app object timeouts are explicit.
        defer { AXUIElementSetMessagingTimeout(system, 0) }
        var lastFocusedPID: pid_t?
        var matchingSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireLive(window, isCancelled: isCancelled)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            AXUIElementSetMessagingTimeout(system, Float(min(0.10, remaining / 2)))
            let focusedApplication = AXRead.element(system, kAXFocusedApplicationAttribute)
            // Do not leave a process-wide timeout override across an await.
            AXUIElementSetMessagingTimeout(system, 0)
            var exactMatch = false
            if let focusedApplication {
                var pid: pid_t = 0
                if AXUIElementGetPid(focusedApplication, &pid) == .success {
                    lastFocusedPID = pid
                    if pid == window.pid {
                        let windowReadBudget = deadline - ProcessInfo.processInfo.systemUptime
                        if windowReadBudget > 0 {
                            AXUIElementSetMessagingTimeout(focusedApplication, Float(min(0.10, windowReadBudget)))
                            if let focused = AXRead.element(focusedApplication, kAXFocusedWindowAttribute),
                               CFEqual(focused, window.element) {
                                exactMatch = true
                            }
                        }
                    }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if exactMatch {
                if matchingSince == nil { matchingSince = now }
                // Two agreeing observations across an event-loop opportunity
                // catch transient focus without waiting for geometry to settle.
                if now - (matchingSince ?? now) >= 0.015 {
                    try requireLive(window, isCancelled: isCancelled)
                    return
                }
            } else { matchingSince = nil }
            let pause = min(0.02, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        try requireLive(window, isCancelled: isCancelled)
        if logFailure {
            print("WINDOWLANE_AX_FOCUS_TIMEOUT expectedPID=\(window.pid) actualPID=\(String(describing: lastFocusedPID))")
        }
        throw WindowBackendError.activationFailed
    }

    private func waitForFrame(_ expected: CGRect, window: WindowCandidate, sizeOnly: Bool = false,
                              isCancelled: () -> Bool) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 1.2
        var actual: CGRect?
        var serverFrame: CGRect?
        var matchingSince: TimeInterval?
        var constrainedSince: TimeInterval?
        var constrainedWidth: CGFloat?
        func matches(_ frame: CGRect) -> Bool {
            (sizeOnly || (abs(frame.minX - expected.minX) <= 1 && abs(frame.minY - expected.minY) <= 1))
                && abs(frame.width - expected.width) <= 1 && abs(frame.height - expected.height) <= 1
        }
        defer { AXUIElementSetMessagingTimeout(window.element, 1.2) }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireLive(window, isCancelled: isCancelled)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            // A frame needs two AX reads. Their combined timeout cannot consume
            // more than the remaining settlement budget.
            AXUIElementSetMessagingTimeout(window.element, Float(min(0.12, remaining / 2)))
            actual = AXRead.frame(window.element)
            serverFrame = window.cgWindowID.flatMap { WindowMatching.frame(windowID: $0, pid: window.pid) }
            let now = ProcessInfo.processInfo.systemUptime
            // AX can briefly publish a target frame before its native animation
            // begins. Require sustained agreement, including WindowServer when
            // the exact stored window ID still belongs to this process.
            if let actual, matches(actual), serverFrame.map(matches) ?? true {
                if matchingSince == nil { matchingSince = now }
                if now - started >= 0.30, now - (matchingSince ?? now) >= 0.20 {
                    try requireLive(window, isCancelled: isCancelled)
                    return
                }
            } else { matchingSince = nil }
            // Learn a lower bound only from a sustained, wider-than-requested
            // size with the requested height, corroborated by WindowServer.
            // An unreadable, moving or position-only failure is not a minimum.
            if sizeOnly, let actual, actual.width > expected.width + 4,
               abs(actual.height - expected.height) <= 1,
               serverFrame.map({ abs($0.width - actual.width) <= 1 && abs($0.height - actual.height) <= 1 }) ?? true {
                if constrainedWidth.map({ abs($0 - actual.width) > 1 }) ?? true {
                    constrainedWidth = actual.width; constrainedSince = now
                }
            } else { constrainedWidth = nil; constrainedSince = nil }
            let pause = min(0.02, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        try requireLive(window, isCancelled: isCancelled)
        if sizeOnly, let width = constrainedWidth, let since = constrainedSince,
           ProcessInfo.processInfo.systemUptime - since >= 0.20 {
            logger.notice("minimum-width window=\(window.id, privacy: .public) bundle=\(window.bundleIdentifier ?? "unknown", privacy: .public) requested=\(expected.width) accepted=\(width)")
            throw WindowBackendError.minimumWidth(width.rounded(.up))
        }
        let error = WindowBackendError.frameNotSettled(expected: expected, actual: actual)
        logger.error("frame-rejected window=\(window.id, privacy: .public) bundle=\(window.bundleIdentifier ?? "unknown", privacy: .public) expected=\(String(describing: expected), privacy: .public) actual=\(String(describing: actual), privacy: .public)")
        print("WINDOWLANE_AX_SETTLE phase=\(sizeOnly ? "size" : "frame") \(error.failureReason ?? "geometry timeout") WindowServer: \(String(describing: serverFrame)).")
        throw error
    }

    private func waitForMinimized(_ expected: Bool, window: WindowCandidate, isCancelled: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var actual: Bool?
        defer { AXUIElementSetMessagingTimeout(window.element, 1.2) }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireLive(window, isCancelled: isCancelled)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            AXUIElementSetMessagingTimeout(window.element, Float(min(0.12, remaining)))
            actual = AXRead.bool(window.element, kAXMinimizedAttribute)
            if actual == expected {
                try requireLive(window, isCancelled: isCancelled)
                return
            }
            let pause = min(0.02, deadline - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        try requireLive(window, isCancelled: isCancelled)
        let error = WindowBackendError.minimizedNotSettled(expected: expected, actual: actual)
        print("WINDOWLANE_AX_SETTLE \(error.failureReason ?? "minimize timeout")")
        throw error
    }

    private func write(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef, action: String,
                       isCancelled: () -> Bool) async throws {
        // During native minimize/resize animation the target app can process a
        // request but miss the response deadline. Only an actual read-back can
        // turn that ambiguous failure into success. Attribute writes are
        // idempotent, so one retry is safe when the requested value is not seen.
        for attempt in 0..<2 {
            try checkCancellation(isCancelled)
            switch attribute {
            case kAXPositionAttribute: diagnostics.positionWrites += 1
            case kAXSizeAttribute: diagnostics.sizeWrites += 1
            case kAXMinimizedAttribute: diagnostics.minimizedWrites += 1
            default: break
            }
            let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
            try checkCancellation(isCancelled)
            if result == .success { return }
            guard result == .cannotComplete else { throw WindowBackendError.failed(action, result) }
            if let actual = AXRead.value(element, attribute), AXRead.equalAttributeValues(actual, value) { return }
            if attempt == 1 { throw WindowBackendError.failed(action, result) }
            await Task.yield()
        }
    }

    private func raise(_ window: AXUIElement, application: AXUIElement, isCancelled: () -> Bool) async throws {
        for attempt in 0..<2 {
            try checkCancellation(isCancelled)
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            try checkCancellation(isCancelled)
            if result == .success { return }
            guard result == .cannotComplete else { throw WindowBackendError.failed("切換視窗", result) }
            if AXRead.bool(application, kAXFrontmostAttribute) == true,
               let focused = AXRead.element(application, kAXFocusedWindowAttribute), CFEqual(focused, window) { return }
            if attempt == 1 { throw WindowBackendError.failed("切換視窗", result) }
            await Task.yield()
        }
    }
}

/// Only explicit captures of the selected windows are made. Pixels remain in memory.
@MainActor
final class PreviewCapture {
    // A timed-out SCK call may still be running inside the framework. Keep the
    // slot occupied until it actually returns instead of accumulating captures.
    private var inFlight: PreviewRequest?
    private var generation: UInt64 = 0
    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Never call during discovery or startup. The UI's preview permission button calls this.
    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    func capture(_ window: WindowCandidate, timeout: Duration = .seconds(2)) async -> NSImage? {
        guard inFlight == nil, isAuthorized, AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        let id = UUID()
        let captureGeneration = generation
        let result: NSImage? = await withTaskCancellationHandler {
            guard inFlight == nil, generation == captureGeneration, !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                guard inFlight == nil, generation == captureGeneration, !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let request = PreviewRequest(id: id, timeout: timeout, continuation: continuation)
                inFlight = request
                request.operation = Task { @MainActor [weak self, request] in
                    guard let self else {
                        request.completeNative(nil)
                        return
                    }
                    let image = await self.captureOnce(window, request: request)
                    if self.inFlight === request { self.inFlight = nil }
                    request.completeNative(image)
                }
                request.timeout = Task { @MainActor [weak request] in
                    guard let request else { return }
                    do { try await Task.sleep(until: request.deadline, clock: .continuous) }
                    catch { return }
                    request.cancel()
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.inFlight?.id == id else { return }
                self.cancelPending()
            }
        }
        // Cancellation can arrive after native completion resumed the waiter but
        // before this actor gets to run the waiting caller again.
        return !Task.isCancelled && generation == captureGeneration ? result : nil
    }

    /// Stop/restore can invalidate optional previews without waiting for SCK.
    /// The native slot remains occupied until the framework callback completes.
    func cancelPending() {
        generation &+= 1
        inFlight?.cancel()
    }

    private func canCapture(_ window: WindowCandidate, request: PreviewRequest) -> Bool {
        guard request.canDeliver, !Task.isCancelled, isAuthorized, AXIsProcessTrusted(),
              !window.application.isTerminated,
              let application = NSRunningApplication(processIdentifier: window.pid),
              !application.isTerminated, window.application.isEqual(application) else { return false }
        return true
    }

    private func captureValue(_ element: AXUIElement, _ attribute: String, request: PreviewRequest) -> CFTypeRef? {
        guard request.canDeliver, !Task.isCancelled else { return nil }
        guard request.limitsAXReadTime else { return AXRead.value(element, attribute) }
        // The deadline task shares MainActor with AX. Give each synchronous read
        // its own short timeout, otherwise a stalled AX call prevents that task
        // from ending the optional transition capture on time.
        let remaining = ContinuousClock.now.duration(to: request.deadline).components
        let remainingSeconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard remainingSeconds >= 0.001 else { return nil }
        let readTimeout = Float(min(0.020, remainingSeconds))
        guard AXUIElementSetMessagingTimeout(element, readTimeout) == .success else { return nil }
        defer { AXUIElementSetMessagingTimeout(element, 0.3) }
        let value = AXRead.value(element, attribute)
        return request.canDeliver && !Task.isCancelled ? value : nil
    }

    private func captureFrame(_ window: WindowCandidate, request: PreviewRequest) -> CGRect? {
        AXRead.frame(window.element, reading: { attribute in
            self.captureValue(window.element, attribute, request: request)
        })
    }

    private func captureOnce(_ window: WindowCandidate, request: PreviewRequest) async -> NSImage? {
        guard canCapture(window, request: request),
              let currentFrame = captureFrame(window, request: request) else { return nil }
        let minimized = captureValue(window.element, kAXMinimizedAttribute, request: request) as? Bool
        guard minimized != true, (!request.limitsAXReadTime || minimized != nil),
              request.canDeliver else { return nil }
        let currentTitle = captureValue(window.element, kAXTitleAttribute, request: request) as? String ?? ""
        guard request.canDeliver, !Task.isCancelled else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard canCapture(window, request: request),
                  let beforeCapture = captureFrame(window, request: request),
                  WindowMatching.close(beforeCapture, currentFrame) else { return nil }
            let matches = content.windows.filter {
                $0.owningApplication?.processID == window.pid
                    && (window.cgWindowID == nil || $0.windowID == window.cgWindowID)
                    && $0.windowLayer == 0
                    && WindowMatching.close($0.frame, currentFrame)
                    && WindowMatching.titlesCompatible(currentTitle, $0.title)
            }
            // A stale CGWindowID alone is insufficient: window IDs can be recycled.
            guard matches.count == 1, let target = matches.first else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let pixelScale = CGFloat(filter.pointPixelScale)
            // ScreenCaptureKit reports content dimensions in points. Preserve
            // native Retina pixels instead of downsampling text previews.
            guard pixelScale.isFinite, pixelScale > 0,
                  let pixelWidth = Int(exactly: (filter.contentRect.width * pixelScale).rounded(.up)),
                  let pixelHeight = Int(exactly: (filter.contentRect.height * pixelScale).rounded(.up)),
                  pixelWidth > 0, pixelHeight > 0 else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = pixelWidth
            configuration.height = pixelHeight
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard canCapture(window, request: request),
                  let afterFrame = captureFrame(window, request: request),
                  WindowMatching.close(afterFrame, currentFrame) else { return nil }
            return NSImage(cgImage: image, size: currentFrame.size)
        } catch {
            // Denied permission, protected content, a closed window, or an unavailable
            // screen all use the same safe app-icon fallback in the interface.
            return nil
        }
    }
}

@MainActor
private final class PreviewRequest {
    let id: UUID
    let deadline: ContinuousClock.Instant
    let limitsAXReadTime: Bool
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var invalidated = false
    var operation: Task<Void, Never>?
    var timeout: Task<Void, Never>?

    var canDeliver: Bool { !invalidated && ContinuousClock.now < deadline }

    init(id: UUID, timeout: Duration, continuation: CheckedContinuation<NSImage?, Never>) {
        self.id = id
        self.deadline = ContinuousClock.now.advanced(by: timeout)
        self.limitsAXReadTime = timeout < .seconds(2)
        self.continuation = continuation
    }

    func cancel() {
        invalidated = true
        operation?.cancel()
        resolve(nil)
    }

    func completeNative(_ image: NSImage?) {
        operation = nil
        resolve(canDeliver ? image : nil)
    }

    private func resolve(_ image: NSImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: image)
    }
}

private enum AXRead {
    static func equalAttributeValues(_ actual: CFTypeRef, _ expected: CFTypeRef) -> Bool {
        guard CFGetTypeID(actual) == CFGetTypeID(expected) else { return false }
        guard CFGetTypeID(expected) == AXValueGetTypeID() else { return CFEqual(actual, expected) }
        let actualValue = actual as! AXValue
        let expectedValue = expected as! AXValue
        guard AXValueGetType(actualValue) == AXValueGetType(expectedValue) else { return false }
        switch AXValueGetType(expectedValue) {
        case .cgPoint:
            var actualPoint = CGPoint.zero, expectedPoint = CGPoint.zero
            guard AXValueGetValue(actualValue, .cgPoint, &actualPoint),
                  AXValueGetValue(expectedValue, .cgPoint, &expectedPoint) else { return false }
            return abs(actualPoint.x - expectedPoint.x) <= 1 && abs(actualPoint.y - expectedPoint.y) <= 1
        case .cgSize:
            var actualSize = CGSize.zero, expectedSize = CGSize.zero
            guard AXValueGetValue(actualValue, .cgSize, &actualSize),
                  AXValueGetValue(expectedValue, .cgSize, &expectedSize) else { return false }
            return abs(actualSize.width - expectedSize.width) <= 1 && abs(actualSize.height - expectedSize.height) <= 1
        default:
            return CFEqual(actual, expected)
        }
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let value = value(element, attribute), CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [AnyObject] else { return nil }
        return array.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable) == .success && isSettable.boolValue
    }

    static func frame(_ element: AXUIElement, reading read: ((String) -> CFTypeRef?)? = nil) -> CGRect? {
        let readAttribute = read ?? { value(element, $0) }
        guard let positionRef = readAttribute(kAXPositionAttribute),
              let sizeRef = readAttribute(kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// Correlation is deliberately conservative; previews are optional, identity is not.
private enum WindowMatching {
    static func frame(windowID: CGWindowID, pid: pid_t) -> CGRect? {
        guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] else { return nil }
        let matches = entries.filter {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        }
        guard matches.count == 1,
              let bounds = matches[0][kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    static func windowInfo() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    static func uniqueID(pid: pid_t, title: String, frame: CGRect, info: [[String: Any]]) -> CGWindowID? {
        let candidates = info.filter { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return close(rect, frame) && titlesCompatible(title, entry[kCGWindowName as String] as? String)
        }
        guard candidates.count == 1 else { return nil }
        return (candidates[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3
            && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }

    static func titlesCompatible(_ axTitle: String, _ captureTitle: String?) -> Bool {
        // CG window names can be redacted without Screen Recording permission.
        guard let captureTitle, !captureTitle.isEmpty, !axTitle.isEmpty else { return true }
        return captureTitle == axTitle
    }
}
