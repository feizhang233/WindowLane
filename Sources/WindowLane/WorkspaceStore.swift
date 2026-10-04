import AppKit
import SwiftUI
import WindowLaneCore

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
    @Published var ratio = 0.84
    @Published var screenIndex = 0
    @Published var pendingRecovery: [RecoveryRecord] = []
    @Published private(set) var recoveryReadFailed = false
    let backend = WindowBackend()
    let capture = PreviewCapture()
    let fixtures = FixtureWindows()
    let background = BackgroundSettings()
    let interaction = InteractionSettings()
    var onShowManager: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onWorkspaceChanged: (() -> Void)?
    var onPrepareFocus: (() -> Void)?
    var onPrepareSwitch: (() -> Void)?
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
    var mainAXFrame: CGRect { WorkspaceLayout.accessibilityFrame(fromAppKit: layout.mainFrame, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0) }

    init(journalURL: URL? = nil) {
        self.journalURL = journalURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowLane/recovery.json")
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
        order.remove(id); entries.removeValue(forKey: id)
        message("已移出工作區；原應用與文件保持開啟。")
    }
    func move(_ id: String, to index: Int) {
        guard !isBusy, !isRunning, let from = order.ids.firstIndex(of: id) else { return }
        order.move(from: from, to: index)
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
        isBusy = true
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
                for entry in sessionEntries {
                    try await self.place(entry, isCancelled: cancelled)
                    try self.requireOperation(token)
                }
                if let item = self.active {
                    try await self.focus(item, isCancelled: cancelled)
                    try self.requireOperation(token)
                }
                self.isBusy = false
                self.message(self.isDemo ? "示範工作區已啟動。" : "工作區已啟動。使用底部切換條、橫向滾輪或 ⌃⌥← / → 切換。")
                self.onWorkspaceChanged?()
            } catch {
                guard self.operationToken == token else { return }
                let reason = error.localizedDescription
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
        guard !isBusy, entries[id] != nil, id != order.activeID else { return }
        guard isRunning else { order.select(id); return }
        let old = active
        guard let next = entries[id] else { return }
        isBusy = true
        let token = UUID(); operationToken = token
        snapshotTask?.cancel()
        onPrepareSwitch?()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelled = { self.operationToken != token || !self.sessionScreenIsAvailable }
            do {
                try self.requireOperation(token)
                try await self.focus(next, isCancelled: cancelled)
                try self.requireOperation(token)
                self.order.select(id)
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
                try await self.focus(item, isCancelled: cancelled)
                try self.requireOperation(token)
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
    private func place(_ entry: ManagedWindow, isCancelled: () -> Bool) async throws {
        guard !isCancelled() else { throw CancellationError() }
        let target = mainAXFrame
        if let c = entry.candidate {
            try await backend.setMinimized(false,for:c,isCancelled:isCancelled)
            try await backend.setFrame(target,for:c,isCancelled:isCancelled)
            guard !isCancelled() else { throw CancellationError() }
            try verifyFrame(target,candidate:c)
        } else if let w = entry.native { w.deminiaturize(nil); w.setFrame(layout.mainFrame,display:true); w.orderFront(nil) }
    }
    private func focus(_ entry: ManagedWindow, isCancelled: () -> Bool) async throws {
        // Release the temporary input window before requesting actual focus.
        guard !isCancelled() else { throw CancellationError() }
        onPrepareFocus?()
        if let c = entry.candidate { try await backend.focus(c,isCancelled:isCancelled) }
        else if let w = entry.native {
            NSApp.activate(ignoringOtherApps:true)
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
    private func healthCheck() {
        refreshPermissions()
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
