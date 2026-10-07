import AppKit
import SwiftUI
import WindowLaneCore
import OSLog

@MainActor final class ManagedWindow: Identifiable {
    let id: String
    let candidate: WindowCandidate?
    let native: NSWindow?
    let appName: String
    let title: String
    let icon: NSImage?
    var originalFrame: CGRect
    var originalMinimized: Bool
    var snapshot: NSImage?
    init(_ candidate: WindowCandidate) {
        self.id = candidate.id; self.candidate = candidate; native = nil
        appName = candidate.appName; title = candidate.title; icon = candidate.icon
        originalFrame = candidate.frame; originalMinimized = candidate.isMinimized
    }
    init(native: NSWindow, index: Int) {
        id = "demo-\(index)"; candidate = nil; self.native = native
        appName = "示範視窗"; title = native.title; icon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        originalFrame = native.frame; originalMinimized = false
    }
}

struct RecoveryRecord: Codable {
    var sessionID: String?
    var pid: Int32
    var windowID: UInt32?
    var bundleID: String?
    var launchTime: TimeInterval?
    var title: String
    var frame: CGRect
    var minimized: Bool
}

private enum WorkspaceLayoutError: LocalizedError {
    case insufficientPaneSpace
    var errorDescription: String? { "目前螢幕放不下這兩個應用所需的最小視窗寬度。" }
}

private struct SavedWorkspaceArea: Codable {
    let mainRatio: Double
    let displayID: UInt32?
}

@MainActor final class WorkspaceStore: ObservableObject {
    @Published var order = WorkspaceOrder()
    @Published var entries: [String: ManagedWindow] = [:]
    @Published var candidates: [WindowCandidate] = []
    @Published var trusted = false
    @Published var captureAllowed = false
    @Published var isRunning = false
    @Published var isBusy = false
    @Published private(set) var isRestoring = false
    @Published var expanded = false
    @Published var isDemo = false
    @Published var status = "加入正在使用的視窗，開始一個專注工作區。"
    @Published var isError = false
    @Published var ratio = 0.84 { didSet { persistAreaSettings() } }
    @Published var screenIndex = 0 { didSet { persistAreaSettings() } }
    @Published var pagePosition = 0.0
    @Published private(set) var isContinuousTurning = false
    @Published var selectedPresetID: UUID?
    @Published var settingsPageRequest = "appearance"
    @Published var settingsPresentation = UUID()
    @Published var pendingRecovery: [RecoveryRecord] = []
    @Published private(set) var recoveryReadFailed = false
    let backend = WindowBackend()
    let capture = PreviewCapture()
    let fixtures = FixtureWindows()
    let background: BackgroundSettings
    let interaction: InteractionSettings
    let presets: WorkspacePresets
    private let areaDefaults: UserDefaults
    private var areaPreferencesReady = false
    private var continuousToken = UUID()
    private var continuousCaptureTask: Task<Void, Never>?
    private var continuousOrigin = 0.0
    private var minimumWindowWidths: [String: CGFloat] = [:]
    private let logger = Logger(subsystem: "com.feizhang.windowlane", category: "workspace")
    var onContinuousPreview: (([NSImage?], [String], BookPageLayout) -> Void)?
    var onContinuousPositionChanged: ((BookPageLayout) -> Void)?
    var onCancelContinuousPreview: (() -> Void)?
    var onShowManager: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onWorkspaceChanged: (() -> Void)?
    var onPrepareFocus: (() -> Void)?
    var onPrepareSwitch: (() -> Void)?
    var onPreparePageTurn: ((NSImage, Int) -> Bool)?
    var onFinishPageTurn: (() async -> Void)?
    var onCancelPageTurn: (() -> Void)?
    // Request-to-focus includes bounded snapshot preparation; presentation also
    // includes the page reveal. Neither metric implies display frame latency.
    private(set) var lastSwitchFocusMilliseconds: Double?
    private(set) var lastSwitchPresentationMilliseconds: Double?
    private var operationToken = UUID()
    private var operationTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var activeScreen: NSScreen?
    private var startingVisibleFrame: CGRect?
    private var startingScreenFrame: CGRect?
    private var healthTimer: Timer?
    private let journalURL: URL
    var ordered: [ManagedWindow] { order.ids.compactMap { entries[$0] } }
    var active: ManagedWindow? { order.activeID.flatMap { entries[$0] } }
    var activeIndex: Int { order.ids.firstIndex(of: order.activeID ?? "") ?? 0 }
    var screen: NSScreen { activeScreen ?? NSScreen.screens[max(0, min(screenIndex, NSScreen.screens.count-1))] }
    var layout: WorkspaceLayout { WorkspaceLayout(visibleFrame: screen.visibleFrame, mainRatio: ratio, expanded: expanded) }
    var bookLayout: BookPageLayout {
        let widths = Dictionary(uniqueKeysWithValues: order.ids.enumerated().compactMap { index, id in
            minimumWindowWidths[id].map { (index, $0) }
        })
        return BookPageLayout(visibleFrame: screen.visibleFrame, mainRatio: ratio,
                              position: pagePosition, count: ordered.count, minimumWidths: widths)
    }
    var isSplit: Bool { bookLayout.isSplit }
    var visibleWindowIDs: [String] { bookLayout.frames.keys.sorted().compactMap { order.ids.indices.contains($0) ? order.ids[$0] : nil } }
    func frameForWindow(_ id: String) -> CGRect {
        guard !expanded, let index = order.ids.firstIndex(of: id), let frame = bookLayout.frames[index] else { return layout.mainFrame }
        return frame
    }
    var mainAXFrame: CGRect { WorkspaceLayout.accessibilityFrame(fromAppKit: layout.mainFrame, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0) }

    init(journalURL: URL? = nil, presetsURL: URL? = nil, defaults: UserDefaults? = nil) {
        let diagnostic = CommandLine.arguments.contains { $0.hasSuffix("smoke-test") || $0 == "--transfer-fixture" }
        let testRoot = journalURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory.appendingPathComponent("WindowLane-tests/\(UUID().uuidString)")
        presets = WorkspacePresets(url: presetsURL ?? (diagnostic ? testRoot.appendingPathComponent("workspaces.json") : nil))
        areaDefaults = defaults ?? (diagnostic ? UserDefaults(suiteName: "WindowLane.area.tests.\(UUID().uuidString)")! : .standard)
        let isolated = diagnostic || defaults != nil
        background = isolated ? BackgroundSettings(defaults: areaDefaults, storageDirectory: testRoot.appendingPathComponent("background")) : BackgroundSettings()
        interaction = InteractionSettings(defaults: isolated ? areaDefaults : .standard)
        self.journalURL = journalURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowLane/recovery.json")
        restoreAreaSettings()
        areaPreferencesReady = true
        refreshPermissions()
        if FileManager.default.fileExists(atPath: self.journalURL.path) {
            do { pendingRecovery = try JSONDecoder().decode([RecoveryRecord].self, from: Data(contentsOf: self.journalURL)) }
            catch {
                recoveryReadFailed = true
                message("復原記錄無法讀取。請先查看記錄並確認視窗已手動復原，再清除記錄。",error:true)
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.healthCheck() }
        }
    }
    func message(_ text: String, error: Bool = false) { status = text; isError = error }
    func refreshPermissions() { trusted = backend.isTrusted; captureAllowed = capture.isAuthorized }
    func refreshWindows() {
        refreshPermissions()
        guard !isBusy else { return }
        guard trusted else { candidates = []; return }
        candidates = backend.listWindows()
    }
    func grantAccessibility() { backend.requestAccessibility(); backend.openAccessibilitySettings() }
    func grantCapture() { capture.requestPermission(); refreshPermissions() }
    func add(_ candidate: WindowCandidate) {
        guard !isBusy else { return }
        if isDemo { clearDemo() }
        guard !isRunning else { message("請先返回管理畫面，再加入視窗。", error: true); return }
        do {
            try order.add(candidate.id)
            entries[candidate.id] = ManagedWindow(candidate)
            message("已加入「\(candidate.title)」。")
        } catch { message(error.localizedDescription, error: true) }
    }
    func addFrontmost() {
        refreshPermissions()
        guard trusted else { message("請先在系統設定中允許 WindowLane 使用輔助使用。", error: true); onShowManager?(); return }
        guard !isRunning else { message("返回管理畫面後即可加入其他視窗。"); return }
        if let window = backend.focusedWindow() { add(window) }
        else { message("找不到可管理的目前視窗。請選擇一般、可調整大小的視窗。", error: true) }
    }
    func remove(_ id: String) {
        guard !isBusy, !isRunning else { return }
        order.remove(id); entries.removeValue(forKey: id); pagePosition = Double(activeIndex)
        message("已移出工作區；原應用與文件保持開啟。")
    }
    func move(_ id: String, to index: Int) {
        guard !isBusy, !isRunning, let from = order.ids.firstIndex(of: id) else { return }
        order.move(from: from, to: index)
        pagePosition = Double(activeIndex)
        onWorkspaceChanged?()
    }
    func loadDemo() {
        guard !isBusy, !isRunning, pendingRecovery.isEmpty else { return }
        fixtures.close(); entries = [:]; order = WorkspaceOrder()
        fixtures.show(); isDemo = true
        for (i,w) in fixtures.windows.enumerated() {
            let item = ManagedWindow(native: w, index: i)
            entries[item.id] = item; try? order.add(item.id)
        }
        pagePosition = 0; selectedPresetID = nil
        message("示範模式：三個可編輯的原生視窗，可測試切換、排序與復原。")
        onShowManager?()
    }
    func clearDemo() {
        guard !isBusy, !isRunning else { return }
        stop(); fixtures.close(); entries = [:]; order = WorkspaceOrder(); isDemo = false
    }
    func start() {
        guard !isBusy, !ordered.isEmpty, !isRunning else { return }
        refreshPermissions()
        guard isDemo || trusted else { message("啟動前，請允許輔助使用權限。", error: true); return }
        guard pendingRecovery.isEmpty, !recoveryReadFailed else { message("請先處理上次未完成的視窗復原。", error: true); return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { message("找不到可用的螢幕。", error: true); return }
        screenIndex = max(0, min(screenIndex, screens.count - 1))
        activeScreen = screens[screenIndex]
        startingVisibleFrame = activeScreen?.visibleFrame
        startingScreenFrame = activeScreen?.frame
        minimumWindowWidths = Dictionary(uniqueKeysWithValues: ordered.compactMap { entry in
            entry.native.map { (entry.id, $0.minSize.width) }
        })
        isBusy = true
        logger.notice("start windows=\(self.ordered.count) position=\(self.pagePosition)")
        message("正在準備工作區…")
        let token = UUID(); operationToken = token
        let sessionEntries = ordered
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for entry in sessionEntries {
                guard self.operationIsCurrent(token) else { return }
                if let c = entry.candidate {
                    entry.snapshot = await self.capture.capture(c)
                    guard self.operationIsCurrent(token) else { return }
                } else if let w = entry.native {
                    entry.snapshot = self.nativeSnapshot(w)
                }
            }
            guard self.operationIsCurrent(token) else { return }
            // Snapshot capture is optional and may suspend. Read original geometry
            // immediately before journaling, not before the capture wait.
            for entry in sessionEntries {
                if let c = entry.candidate {
                    guard self.backend.isAlive(c), let frame = self.backend.frame(of: c),
                          let minimized = self.backend.isMinimized(c) else {
                        self.isBusy = false
                        self.message("「\(entry.title)」已關閉或無法讀取，請將它移出後重新加入。", error: true)
                        return
                    }
                    entry.originalFrame = frame; entry.originalMinimized = minimized
                } else if let w = entry.native {
                    entry.originalFrame = w.frame; entry.originalMinimized = w.isMiniaturized
                }
            }
            do { if !self.isDemo { try self.writeJournal(sessionEntries.compactMap(self.recoveryRecord)) } }
            catch {
                self.isBusy = false
                self.message("無法儲存復原記錄，尚未移動任何視窗：\(error.localizedDescription)", error: true)
                return
            }
            self.isRunning = true
            let cancelled = { self.operationToken != token || !self.sessionScreenIsAvailable }
            do {
                // All windows stay open at the same frame. Prepare once so a
                // normal switch only changes the frontmost window and focus.
                var fallbackToSinglePage = false
                do { try await self.applyCurrentLayout(token: token) }
                catch WorkspaceLayoutError.insufficientPaneSpace {
                    self.pagePosition = Double(self.activeIndex)
                    try await self.applyCurrentLayout(token: token)
                    fallbackToSinglePage = true
                }
                // Hiding old tool panels can restore AppKit's previous key
                // window. Complete those changes before confirming new focus.
                self.onWorkspaceChanged?()
                if let item = self.active {
                    try await self.focus(item, isCancelled: cancelled)
                    try self.requireOperation(token)
                }
                try await self.settleVisiblePanes(focused: self.active, token: token)
                self.isBusy = false
                self.message(fallbackToSinglePage ? "這兩個應用的最小寬度超出螢幕空間，已以單頁啟動。" :
                    (self.isDemo ? "示範工作區已啟動。" : "工作區已啟動。使用底部切換條、橫向滾輪或 ⌃⌥← / → 切換。"))
                self.onWorkspaceChanged?()
            } catch {
                guard self.operationToken == token else { return }
                let reason = error.localizedDescription
                self.logger.error("start-failed reason=\(reason, privacy: .private)")
                self.stop()
                self.message("無法完成視窗排列，正在復原：\(reason)", error: true)
                self.onShowManager?()
            }
        }
    }
    func select(index: Int) {
        guard index >= 0, index < order.ids.count else { return }
        select(order.ids[index])
    }
    func step(_ delta: Int) {
        guard delta == -1 || delta == 1 else { return }
        select(index: activeIndex + delta)
    }
    func select(_ id: String) {
        guard !isBusy, entries[id] != nil, id != order.activeID || isSplit else { return }
        guard isRunning else { order.select(id); pagePosition = Double(activeIndex); return }
        let old = active
        guard let next = entries[id] else { return }
        let direction = (order.ids.firstIndex(of: id) ?? activeIndex) > activeIndex ? 1 : -1
        let wasSplit = isSplit
        let requestedAt = ProcessInfo.processInfo.systemUptime
        lastSwitchFocusMilliseconds = nil; lastSwitchPresentationMilliseconds = nil
        isBusy = true
        let token = UUID(); operationToken = token
        snapshotTask?.cancel()
        onPrepareSwitch?()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelled = { self.operationToken != token || !self.sessionScreenIsAvailable }
            do {
                try self.requireOperation(token)
                // A page must show the current content, never a stale thumbnail.
                // Capture has a short budget; missing/slow capture skips motion.
                var preparedPage = false
                if !wasSplit, let old, self.onPreparePageTurn != nil,
                   !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let image = await self.pageTurnSnapshot(old)
                    try self.requireOperation(token)
                    if let image { preparedPage = self.onPreparePageTurn?(image, direction) ?? false }
                }
                if wasSplit {
                    self.pagePosition = Double(self.order.ids.firstIndex(of: id) ?? 0)
                    for entry in self.ordered { try await self.place(entry, isCancelled: cancelled); try self.requireOperation(token) }
                }
                try await self.focus(next, isCancelled: cancelled)
                try self.requireOperation(token)
                self.lastSwitchFocusMilliseconds = (ProcessInfo.processInfo.systemUptime - requestedAt) * 1_000
                self.order.select(id)
                self.pagePosition = Double(self.activeIndex)
                if preparedPage { await self.onFinishPageTurn?() }
                try self.requireOperation(token)
                self.lastSwitchPresentationMilliseconds = (ProcessInfo.processInfo.systemUptime - requestedAt) * 1_000
                self.isBusy = false
                self.message("\(next.appName) · \(next.title)")
                self.onWorkspaceChanged?()
                if let old { self.refreshSnapshot(old, token: token) }
            } catch {
                guard self.operationToken == token else { return }
                self.stop()
                self.message("切換失敗，正在復原視窗：\(error.localizedDescription)", error: true)
                self.onShowManager?()
            }
        }
    }

    private func pageTurnSnapshot(_ entry: ManagedWindow) async -> NSImage? {
        if let candidate = entry.candidate {
            return await capture.capture(candidate, timeout: .milliseconds(100))
        }
        // Include the native title bar so the page matches the prepared frame.
        guard let window = entry.native, let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func refreshSnapshot(_ entry: ManagedWindow, token: UUID) {
        snapshotTask = Task(priority: .background) { @MainActor [weak self, weak entry] in
            // Let the real window and rail present before optional preview work.
            await Task.yield()
            guard let self, let entry, self.operationIsCurrent(token), self.isRunning,
                  self.entries[entry.id] === entry else { return }
            let image: NSImage?
            if let c = entry.candidate { image = await self.capture.capture(c) }
            else if let w = entry.native { image = self.nativeSnapshot(w) }
            else { image = nil }
            guard self.operationIsCurrent(token), self.isRunning, let image,
                  self.entries[entry.id] === entry else { return }
            entry.snapshot = image
            self.objectWillChange.send()
        }
    }

    func toggleExpanded() {
        guard isRunning, !isBusy, let item = active else { return }
        expanded.toggle(); isBusy = true
        let token = UUID(); operationToken = token
        snapshotTask?.cancel()
        onPrepareSwitch?()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelled = { self.operationToken != token || !self.sessionScreenIsAvailable }
            do {
                // Expansion is an explicit layout change. Align the entire
                // stack so subsequent switches remain geometry-free.
                for entry in self.ordered {
                    try await self.place(entry, isCancelled: cancelled)
                    try self.requireOperation(token)
                }
                self.onWorkspaceChanged?()
                try await self.focus(item, isCancelled: cancelled)
                try self.requireOperation(token)
                try await self.settleVisiblePanes(focused: item, token: token)
                self.isBusy = false; self.onWorkspaceChanged?()
            } catch {
                guard self.operationToken == token else { return }
                self.stop()
                self.message("調整大小失敗，正在復原：\(error.localizedDescription)", error: true)
                self.onShowManager?()
            }
        }
    }
    func stop() {
        guard !isRestoring else { return }
        operationToken = UUID()
        operationTask?.cancel(); snapshotTask?.cancel(); capture.cancelPending()
        cancelContinuousPaging()
        onCancelPageTurn?()
        let interruptedTask = operationTask
        operationTask = nil; snapshotTask = nil
        guard isRunning else {
            isBusy = false; activeScreen = nil
            onWorkspaceChanged?()
            return
        }
        let sessionEntries = ordered
        let demoSession = isDemo
        let allRecords = sessionEntries.compactMap(recoveryRecord)
        isRunning = false; expanded = false; isBusy = true; isRestoring = true
        onWorkspaceChanged?()
        message("正在恢復視窗位置與尺寸…")
        restorationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Old AX writes must unwind before restoration starts. The separate
            // restoration task is never cancelled by repeated Stop requests.
            await interruptedTask?.value
            var failures: [RecoveryRecord] = []
            var failureTitles: [String] = []
            for entry in sessionEntries {
                do { try await self.restore(entry) }
                catch {
                    if let c = entry.candidate, self.backend.isAlive(c) {
                        failureTitles.append(entry.title)
                        if let record = self.recoveryRecord(entry) { failures.append(record) }
                    }
                }
            }
            if !demoSession {
                do {
                    try self.writeJournal(failures)
                    self.pendingRecovery = failures
                } catch {
                    // Do not let a failed journal update masquerade as an empty
                    // recovery queue or permit another session to overwrite it.
                    self.pendingRecovery = allRecords
                    failureTitles.append("復原記錄無法更新")
                }
            }
            self.activeScreen = nil
            self.isRestoring = false; self.isBusy = false
            self.onWorkspaceChanged?()
            if failureTitles.isEmpty { self.message("已退出工作區，視窗已恢復原位置與尺寸。") }
            else { self.message("部分視窗尚未復原：\(failureTitles.joined(separator: "、"))。請按「重試復原」。", error: true) }
        }
    }
    func recover() {
        refreshPermissions()
        guard trusted, !isRunning, !isBusy, !recoveryReadFailed else { return }
        let records = pendingRecovery
        isBusy = true; isRestoring = true
        message("正在重試復原…")
        restorationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining: [RecoveryRecord] = []
            var reasons: [String] = []
            for record in records {
                let c: WindowCandidate
                switch await self.backend.recoveryCandidate(for:record) {
                case .found(let candidate): c = candidate
                case .processEnded: continue
                case .unavailable(let reason): remaining.append(record); reasons.append(reason); continue
                }
                do {
                    try await self.backend.setMinimized(false, for: c)
                    try await self.backend.setFrame(record.frame, for: c)
                    try self.verifyFrame(record.frame, candidate: c)
                    try await self.backend.setMinimized(record.minimized, for: c)
                } catch { remaining.append(record); reasons.append(error.localizedDescription) }
            }
            do {
                try self.writeJournal(remaining)
                self.pendingRecovery = remaining
                self.message(remaining.isEmpty ? "視窗復原完成。" : "還有 \(remaining.count) 個視窗等待復原。\(reasons.first ?? "請保持原應用開啟後重試。")", error: !remaining.isEmpty)
            } catch { self.message("無法更新復原記錄：\(error.localizedDescription)", error: true) }
            self.isRestoring = false; self.isBusy = false
        }
    }
    func waitForRestoration() async { await restorationTask?.value }
    func refocusActive() {
        guard isRunning, !isBusy, let item = active else { return }
        let token = UUID(); operationToken = token; isBusy = true
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.focus(item,isCancelled:{ self.operationToken != token || !self.sessionScreenIsAvailable })
                try self.requireOperation(token)
                self.isBusy = false
            } catch {
                guard self.operationToken == token else { return }
                self.stop(); self.onShowManager?()
            }
        }
    }
    private var sessionScreenIsAvailable: Bool {
        guard let activeScreen else { return false }
        let id = activeScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let current = NSScreen.screens.first(where:{ $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == id }) else { return false }
        return current.frame == startingScreenFrame && current.visibleFrame == startingVisibleFrame
    }
    private func operationIsCurrent(_ token: UUID) -> Bool {
        operationToken == token && !Task.isCancelled
    }
    private func requireOperation(_ token: UUID) throws {
        guard operationIsCurrent(token) else { throw CancellationError() }
    }
    func revealRecoveryRecord() { NSWorkspace.shared.activateFileViewerSelecting([journalURL]) }
    func acknowledgeManualRecovery() {
        guard !isRunning, !isBusy else { return }
        do {
            let wasDemo = isDemo
            isDemo = false
            defer { isDemo = wasDemo }
            try writeJournal([])
            pendingRecovery = []
            recoveryReadFailed = false
            message("已確認手動復原，可建立新的工作區。")
        } catch { message("無法更新復原記錄：\(error.localizedDescription)",error:true) }
    }
    private func place(_ entry: ManagedWindow, frame: CGRect? = nil, isCancelled: () -> Bool) async throws {
        guard !isCancelled() else { throw CancellationError() }
        let appKitTarget = frame ?? frameForWindow(entry.id)
        let target = WorkspaceLayout.accessibilityFrame(fromAppKit: appKitTarget, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        if let c = entry.candidate {
            try await backend.setMinimized(false,for:c,isCancelled:isCancelled)
            try await backend.setFrame(target,for:c,isCancelled:isCancelled)
            guard !isCancelled() else { throw CancellationError() }
            try verifyFrame(target,candidate:c)
        } else if let w = entry.native {
            w.deminiaturize(nil); w.setFrame(appKitTarget,display:true); w.orderFront(nil)
            if w.frame.width > appKitTarget.width + 4, abs(w.frame.height - appKitTarget.height) <= 1 {
                throw WindowBackendError.minimumWidth(w.frame.width.rounded(.up))
            }
            guard abs(w.frame.minX - appKitTarget.minX) <= 4, abs(w.frame.minY - appKitTarget.minY) <= 4,
                  abs(w.frame.width - appKitTarget.width) <= 4, abs(w.frame.height - appKitTarget.height) <= 4 else {
                throw WindowBackendError.frameNotSettled(expected: appKitTarget, actual: w.frame)
            }
        }
    }

    private func applyCurrentLayout(token: UUID) async throws {
        let cancelled = { self.operationToken != token || !self.sessionScreenIsAvailable }
        // A rejection may reveal one new application constraint per attempt.
        // Bound retries to the small managed set; never keep resizing indefinitely.
        for _ in 0...ordered.count {
            try requireOperation(token)
            guard !isSplit || bookLayout.fitsMinimumWidths else { throw WorkspaceLayoutError.insufficientPaneSpace }
            var learnedWidth = false
            for entry in ordered {
                do { try await place(entry, isCancelled: cancelled) }
                catch WindowBackendError.minimumWidth(let width) {
                    guard isSplit, visibleWindowIDs.contains(entry.id), width.isFinite,
                          width > (minimumWindowWidths[entry.id] ?? 0) + 1 else { throw WindowBackendError.minimumWidth(width) }
                    minimumWindowWidths[entry.id] = width
                    logger.notice("adapt-width window=\(entry.id, privacy: .public) width=\(width) position=\(self.pagePosition)")
                    learnedWidth = true
                    break
                }
                try requireOperation(token)
            }
            if !learnedWidth { return }
        }
        throw WorkspaceLayoutError.insufficientPaneSpace
    }

    private func currentNativeFrames() throws -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for entry in ordered {
            if let window = entry.native { result[entry.id] = window.frame }
            else if let candidate = entry.candidate, let frame = backend.frame(of: candidate) {
                result[entry.id] = WorkspaceLayout.appKitFrame(fromAccessibility: frame,
                    primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
            } else { throw WindowBackendError.windowUnavailable }
        }
        return result
    }

    private func focus(_ entry: ManagedWindow, isCancelled: () -> Bool) async throws {
        // Release the temporary input window before requesting actual focus.
        guard !isCancelled() else { throw CancellationError() }
        onPrepareFocus?()
        if let c = entry.candidate { try await backend.focus(c,isCancelled:isCancelled) }
        else if let w = entry.native {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps:true) }
            w.makeKeyAndOrderFront(nil)
            // App activation and panel key-focus restoration can complete on a
            // later run-loop turn. Commit selection only after real key focus.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            var focusedSince: TimeInterval?
            var reaffirmedAfterActivation = false
            while true {
                guard !isCancelled() else { throw CancellationError() }
                let now = ProcessInfo.processInfo.systemUptime
                if NSApp.isActive, NSApp.keyWindow === w {
                    if let focusedSince, now - focusedSince >= 0.01 { return }
                    if focusedSince == nil { focusedSince = now }
                } else {
                    focusedSince = nil
                    if NSApp.isActive, !reaffirmedAfterActivation {
                        w.makeKeyAndOrderFront(nil)
                        reaffirmedAfterActivation = true
                    }
                }
                guard now < deadline else { throw WindowBackendError.activationFailed }
                try await Task.sleep(nanoseconds:10_000_000)
            }
        }
    }
    private func raiseVisiblePanes(focusedID: String? = nil) throws {
        guard isSplit, !expanded else { return }
        // Activation can bring an application's whole window group forward.
        // Raise panes after focus settles, with the focused pane ordered last.
        let ids = visibleWindowIDs.filter { $0 != focusedID } + visibleWindowIDs.filter { $0 == focusedID }
        for id in ids {
            guard let entry = entries[id] else { continue }
            if let window = entry.native { window.orderFrontRegardless() }
            else if let candidate = entry.candidate { try backend.raiseForInteraction(candidate) }
        }
    }
    private func settleVisiblePanes(focused: ManagedWindow?, token: UUID) async throws {
        guard isSplit, !expanded else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var stableSince: TimeInterval?
        var retries = 0
        var lastRaise = ProcessInfo.processInfo.systemUptime
        try raiseVisiblePanes(focusedID: focused?.id)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireOperation(token)
            guard sessionScreenIsAvailable else { throw CancellationError() }
            let focusMatches = focused.map { entry in
                entry.native.map { NSApp.isActive && NSApp.keyWindow === $0 }
                    ?? entry.candidate.map { backend.isFocused($0) } ?? false
            } ?? true
            let managedNumbers = ordered.compactMap { $0.native.map { $0.windowNumber } ?? $0.candidate?.cgWindowID.map(Int.init) }
            let visibleNumbers = visibleWindowIDs.compactMap { id in
                entries[id].flatMap { $0.native.map { $0.windowNumber } ?? $0.candidate?.cgWindowID.map(Int.init) }
            }
            let server = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let front = server.compactMap { $0[kCGWindowNumber as String] as? Int }
                .filter { managedNumbers.contains($0) }.prefix(2)
            let orderMatches = visibleNumbers.count != 2 || (front.count == 2 && visibleNumbers.allSatisfy { front.contains($0) })
            let now = ProcessInfo.processInfo.systemUptime
            if focusMatches && orderMatches {
                if stableSince == nil { stableSince = now }
                if now - (stableSince ?? now) >= 0.06 { return }
            } else {
                stableSince = nil
                // Application activation can restore its old key window on a
                // later turn. Reaffirm the real target, then verify the stack.
                if retries < 2, now - lastRaise >= 0.10 {
                    if let focused { try await focus(focused, isCancelled: { self.operationToken != token || !self.sessionScreenIsAvailable }) }
                    try raiseVisiblePanes(focusedID: focused?.id)
                    retries += 1; lastRaise = ProcessInfo.processInfo.systemUptime
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WindowBackendError.activationFailed
    }
    private func restore(_ entry: ManagedWindow) async throws {
        if let c = entry.candidate {
            guard backend.isAlive(c) else { return }
            try await backend.setMinimized(false,for:c)
            try await backend.setFrame(entry.originalFrame,for:c)
            try verifyFrame(entry.originalFrame,candidate:c)
            try await backend.setMinimized(entry.originalMinimized,for:c)
        } else if let w = entry.native {
            w.setFrame(entry.originalFrame,display:true); w.orderFront(nil)
            if entry.originalMinimized { w.miniaturize(nil) }
        }
    }
    private func verifyFrame(_ expected:CGRect, candidate:WindowCandidate) throws {
        guard let actual = backend.frame(of:candidate),
              abs(actual.minX-expected.minX) <= 4, abs(actual.minY-expected.minY) <= 4,
              abs(actual.width-expected.width) <= 4, abs(actual.height-expected.height) <= 4 else {
            throw NSError(domain:"WindowLane",code:1,userInfo:[NSLocalizedDescriptionKey:"「\(candidate.title)」未接受指定尺寸或位置，可能受應用最小尺寸或目前螢幕限制。"])
        }
    }
    private func recoveryRecord(_ entry: ManagedWindow) -> RecoveryRecord? {
        guard let c = entry.candidate else { return nil }
        return RecoveryRecord(sessionID:c.id,pid:c.pid,windowID:c.cgWindowID,bundleID:c.bundleIdentifier,launchTime:c.launchDate?.timeIntervalSince1970,title:c.title,frame:entry.originalFrame,minimized:entry.originalMinimized)
    }
    private func writeJournal(_ records: [RecoveryRecord]) throws {
        try FileManager.default.createDirectory(at:journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(records).write(to:journalURL,options:.atomic)
    }
    private func nativeSnapshot(_ window: NSWindow) -> NSImage? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return nil }
        view.cacheDisplay(in:view.bounds,to:rep)
        let image = NSImage(size:view.bounds.size); image.addRepresentation(rep); return image
    }
    func openWorkspaceSettings() { settingsPageRequest = "workspace"; onShowSettings?() }

    private func persistAreaSettings() {
        guard areaPreferencesReady, !NSScreen.screens.isEmpty else { return }
        let index = max(0, min(screenIndex, NSScreen.screens.count - 1))
        let displayID = (NSScreen.screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let value = SavedWorkspaceArea(mainRatio: min(0.9, max(0.8, ratio.isFinite ? ratio : 0.84)), displayID: displayID)
        if let data = try? JSONEncoder().encode(value) { areaDefaults.set(data, forKey: "WindowLane.area.v1") }
    }
    private func restoreAreaSettings() {
        guard let data = areaDefaults.data(forKey: "WindowLane.area.v1"),
              let saved = try? JSONDecoder().decode(SavedWorkspaceArea.self, from: data) else { return }
        ratio = saved.mainRatio.isFinite ? min(0.9, max(0.8, saved.mainRatio)) : 0.84
        if let id = saved.displayID, let index = NSScreen.screens.firstIndex(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) { screenIndex = index }
    }
    private func descriptor(_ entry: ManagedWindow) -> WorkspaceWindowDescriptor {
        if let candidate = entry.candidate { return descriptor(candidate) }
        return WorkspaceWindowDescriptor(id: entry.id, appName: entry.appName, title: entry.title,
                                         nativeDemoIndex: Int(entry.id.replacingOccurrences(of: "demo-", with: "")))
    }
    private func descriptor(_ candidate: WindowCandidate) -> WorkspaceWindowDescriptor {
        WorkspaceWindowDescriptor(id: candidate.id, bundleIdentifier: candidate.bundleIdentifier,
                                  appName: candidate.appName, title: candidate.title, processID: candidate.pid,
                                  windowID: candidate.cgWindowID, launchTime: candidate.launchDate?.timeIntervalSince1970)
    }
    func savePreset(name: String, replacing id: UUID? = nil) {
        do { try savePresetThrowing(name: name, replacing: id) }
        catch { message(error.localizedDescription, error: true) }
    }
    func savePresetThrowing(name: String, replacing id: UUID? = nil) throws {
        guard !isBusy else { throw WorkspacePresetError.noWindows }
        let saved = try presets.save(name: name, windows: ordered.map(descriptor), mainRatio: ratio,
                                     displayID: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                                     displayName: screen.localizedName, activeSlot: activeIndex,
                                     pagePosition: pagePosition, replacing: id)
        selectedPresetID = saved.id
        message("已儲存「\(saved.name)」。")
    }
    @discardableResult func applyPreset(_ id: UUID) -> Bool {
        guard !isRunning, !isBusy, let preset = presets.items.first(where: { $0.id == id }) else { return false }
        let demoPreset = preset.windows.allSatisfy { $0.nativeDemoIndex != nil }
        var available: [String: ManagedWindow] = [:]
        let descriptors: [WorkspaceWindowDescriptor]
        if demoPreset {
            fixtures.show()
            for (index, window) in fixtures.windows.enumerated() {
                let entry = ManagedWindow(native: window, index: index); available[entry.id] = entry
            }
            descriptors = fixtures.windows.enumerated().map {
                WorkspaceWindowDescriptor(id: "demo-\($0.offset)", appName: "示範視窗", title: $0.element.title, nativeDemoIndex: $0.offset)
            }
        } else {
            refreshWindows()
            descriptors = candidates.map(descriptor)
            for candidate in candidates { available[candidate.id] = ManagedWindow(candidate) }
        }
        let result = WorkspacePresetMatcher.resolve(preset, among: descriptors)
        guard result.isComplete else {
            message("「\(preset.name)」有視窗尚未開啟或無法唯一辨識：\(result.unresolvedLabels.joined(separator: "、"))。請先開啟原文件，再選擇排版。", error: true)
            return false
        }
        let next = Dictionary(uniqueKeysWithValues: result.matchedIDs.compactMap { key in available[key].map { (key, $0) } })
        guard next.count == preset.windows.count else { return false }
        entries = next; order = WorkspaceOrder(ids: result.matchedIDs, activeID: result.matchedIDs[preset.activeSlot])
        isDemo = demoPreset; ratio = preset.mainRatio; pagePosition = preset.effectivePagePosition
        selectedPresetID = id
        let display = preset.displayID.flatMap { target in NSScreen.screens.firstIndex {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target
        }}
        if let display { screenIndex = display; message("已選擇「\(preset.name)」，按「啟動工作區」套用。") }
        else { message("已選擇「\(preset.name)」；原螢幕未連接，將使用目前螢幕。") }
        onWorkspaceChanged?()
        return true
    }
    func loadNativeFixture(windows: [NSWindow]) {
        guard !isRunning, !isBusy else { return }
        entries = [:]; order = WorkspaceOrder(); isDemo = true
        for (index, window) in windows.enumerated() {
            let entry = ManagedWindow(native: window, index: index)
            entries[entry.id] = entry; try? order.add(entry.id)
        }
        pagePosition = 0.5
        message("拖放驗證：兩個真實視窗並排。")
    }

    func beginContinuousPaging() {
        guard isRunning, !isBusy, !expanded, ordered.count > 1 else { return }
        continuousOrigin = pagePosition; isContinuousTurning = true; isBusy = true
        continuousToken = UUID(); let token = continuousToken
        snapshotTask?.cancel(); capture.cancelPending(); onCancelPageTurn?()
        let images = ordered.map { entry in entry.native.flatMap(nativeSnapshot) ?? entry.snapshot }
        onContinuousPreview?(images, ordered.map(\.title), bookLayout)
        // Refresh only the actually displayed source. Other pages remain honest
        // cached previews until their real native windows are revealed on release.
        if let source = active, source.candidate != nil {
            continuousCaptureTask = Task { @MainActor [weak self, weak source] in
                guard let self, let source else { return }
                let image = await self.pageTurnSnapshot(source)
                guard self.continuousToken == token, self.isContinuousTurning, let image else { return }
                source.snapshot = image
                self.onContinuousPreview?(self.ordered.map(\.snapshot), self.ordered.map(\.title), self.bookLayout)
            }
        }
    }
    func updateContinuousPaging(position: Double) {
        guard isContinuousTurning, position.isFinite else { return }
        pagePosition = min(Double(max(0, ordered.count - 1)), max(0, position))
        onContinuousPositionChanged?(bookLayout)
    }
    func cancelContinuousPaging() {
        continuousToken = UUID(); continuousCaptureTask?.cancel(); continuousCaptureTask = nil
        onCancelContinuousPreview?()
        if isContinuousTurning { pagePosition = continuousOrigin; isContinuousTurning = false; isBusy = false }
    }
    func commitContinuousPaging(position: Double, preserveFocus: Bool = false) {
        guard isRunning, !expanded, ordered.count > 1, position.isFinite,
              !isBusy || isContinuousTurning else { return }
        let previousPosition = isContinuousTurning ? continuousOrigin : pagePosition
        let previousActiveID = order.activeID
        let previousFrames: [String: CGRect]
        do { previousFrames = try currentNativeFrames() }
        catch {
            cancelContinuousPaging()
            message("無法讀取視窗尺寸，已保留原排版。", error: true)
            return
        }
        continuousToken = UUID(); continuousCaptureTask?.cancel(); continuousCaptureTask = nil
        isContinuousTurning = false; isBusy = true
        pagePosition = BookPageLayout(visibleFrame: screen.visibleFrame, mainRatio: ratio, position: position, count: ordered.count).position
        let targetIndex = min(ordered.count - 1, max(0, Int(pagePosition.rounded())))
        let selected = preserveFocus && visibleWindowIDs.contains(order.activeID ?? "") ? active : ordered[targetIndex]
        let token = UUID(); operationToken = token
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelled = { self.operationToken != token || !self.sessionScreenIsAvailable }
            do {
                try await self.applyCurrentLayout(token: token)
                self.onCancelContinuousPreview?()
                self.onWorkspaceChanged?()
                if let selected {
                    if !preserveFocus { try await self.focus(selected, isCancelled: cancelled) }
                    try self.requireOperation(token)
                    self.order.select(selected.id)
                }
                try await self.settleVisiblePanes(focused: preserveFocus ? nil : selected, token: token)
                try self.requireOperation(token)
                self.onCancelContinuousPreview?(); self.isBusy = false
                self.message(self.isSplit ? "兩個視窗可直接操作與拖放。繼續側滑即可翻頁。" : (self.active?.title ?? "工作區"))
                self.onWorkspaceChanged?()
            } catch {
                guard self.operationIsCurrent(token) else { return }
                self.logger.error("layout-rejected position=\(self.pagePosition) reason=\(error.localizedDescription, privacy: .private)")
                self.pagePosition = previousPosition
                if let previousActiveID { self.order.select(previousActiveID) }
                do {
                    // Restore the last accepted real frames, never overwrite the
                    // original recovery values captured before workspace Start.
                    for entry in self.ordered {
                        guard let frame = previousFrames[entry.id] else { throw WindowBackendError.windowUnavailable }
                        try await self.place(entry, frame: frame, isCancelled: cancelled)
                        try self.requireOperation(token)
                    }
                    self.onCancelContinuousPreview?()
                    self.onWorkspaceChanged?()
                    if !preserveFocus, let active = self.active { try await self.focus(active, isCancelled: cancelled) }
                    try self.requireOperation(token)
                    try await self.settleVisiblePanes(focused: preserveFocus ? nil : self.active, token: token)
                    self.onCancelContinuousPreview?(); self.isBusy = false
                    self.message("此應用未接受並排尺寸，已回到原排版。可使用逐頁切換。", error: true)
                    self.logger.notice("layout-rollback-complete position=\(previousPosition)")
                    self.onWorkspaceChanged?()
                } catch {
                    guard self.operationIsCurrent(token) else { return }
                    self.logger.error("layout-rollback-failed reason=\(error.localizedDescription, privacy: .private)")
                    self.stop(); self.message("原排版未能恢復，正在復原視窗：\(error.localizedDescription)", error: true); self.onShowManager?()
                }
            }
        }
    }
    func showHalfPage() {
        guard isRunning, !isBusy, ordered.count > 1 else { return }
        let lower = activeIndex < ordered.count - 1 ? activeIndex : activeIndex - 1
        commitContinuousPaging(position: Double(lower) + 0.5)
    }
    func revealAdjacentForDrag(_ delta: Int) {
        guard isRunning, !isBusy, !expanded, delta == 1 || delta == -1 else { return }
        let neighbor = activeIndex + delta
        guard ordered.indices.contains(neighbor) else { return }
        commitContinuousPaging(position: Double(min(activeIndex, neighbor)) + 0.5, preserveFocus: true)
    }
    func trackVisibleFocus() {
        guard isRunning, !isBusy, isSplit else { return }
        for id in visibleWindowIDs {
            guard let entry = entries[id] else { continue }
            let focused = entry.native.map { NSApp.keyWindow === $0 } ?? entry.candidate.map { backend.isFocused($0) } ?? false
            if focused { order.select(id); return }
        }
    }
    private func healthCheck() {
        refreshPermissions()
        trackVisibleFocus()
        guard isRunning, !isBusy else { return }
        if !isDemo && !trusted { stop(); message("輔助使用權限已關閉，請重新允許後重試復原。",error:true); onShowManager?(); return }
        if let activeScreen {
            let screenID = activeScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let current = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == screenID }
            if current == nil || current?.visibleFrame != startingVisibleFrame || current?.frame != startingScreenFrame {
                stop(); message("螢幕配置已變更，工作區已退出。請選擇目前螢幕後再啟動。"); onShowManager?(); return
            }
        }

        let closed = ordered.filter { $0.candidate.map { !backend.isAlive($0) } ?? ($0.native?.isVisible == false && $0.id == order.activeID) }
        if !closed.isEmpty {
            stop()
            for item in closed { order.remove(item.id); entries.removeValue(forKey:item.id) }
            message("有視窗已關閉，工作區已退出；其餘視窗已嘗試復原。"); onShowManager?()
        }
    }
}
