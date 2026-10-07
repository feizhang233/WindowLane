import AppKit
import SwiftUI
import WindowLaneCore

@main
struct WindowLaneMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: WorkspaceStore = {
        // Explicit fixture test runs never consume or overwrite a user's
        // unresolved recovery journal. Each run owns a distinct temporary file.
        let testMode = CommandLine.arguments.contains { $0.hasSuffix("smoke-test") || $0 == "--transfer-fixture" }
        let testJournal = testMode ? FileManager.default.temporaryDirectory.appendingPathComponent("WindowLane-tests/\(UUID().uuidString)/recovery.json") : nil
        return WorkspaceStore(journalURL:testJournal)
    }()
    var manager: NSWindow!
    var panels: WorkspacePanels!
    var settingsWindow: NSWindow?
    var scrollRouter: HorizontalScrollRouter?
    private var terminationPending = false
    var shortcuts: GlobalShortcuts?
    var statusItem: NSStatusItem?
    var screenObserver: NSObjectProtocol?
    var transferFixture: TransferFixture?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let diagnostic = CommandLine.arguments.contains { $0.hasSuffix("smoke-test") || $0 == "--fixture-host" || $0 == "--transfer-fixture" }
        if !diagnostic, let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first(where:{ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            // Two managers must never race over the same external windows and journal.
            existing.activate(options:[])
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--ui-preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        createMenu()
        manager = NSWindow(contentRect:NSRect(x:0,y:0,width:1010,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        manager.title = "WindowLane — 視窗工作區"
        manager.identifier = NSUserInterfaceItemIdentifier("windowlane.manager")
        manager.minSize = NSSize(width:880,height:650)
        manager.isReleasedWhenClosed = false
        manager.delegate = self
        manager.isOpaque = false
        manager.backgroundColor = .clear
        manager.titlebarAppearsTransparent = true
        manager.titleVisibility = .hidden
        manager.contentView = NSHostingView(rootView:ManagerView(store:store))
        manager.center()
        panels = WorkspacePanels(store:store)
        scrollRouter = HorizontalScrollRouter(store:store,panels:panels)
        store.onShowManager = { [weak self] in self?.showManager() }
        store.onShowSettings = { [weak self] in self?.showSettings() }
        store.onPrepareFocus = { [weak self] in self?.panels.releaseInputShield() }
        store.onWorkspaceChanged = { [weak self] in
            guard let self else { return }
            if self.store.isRunning, self.manager.isVisible { self.manager.orderOut(nil) }
            self.panels.update()
            self.scrollRouter?.updateMonitoring()
        }
        store.onPrepareSwitch = { [weak self] in self?.panels.beginFocusHandoff() }
        store.onPreparePageTurn = { [weak self] image, direction in
            guard let self else { return false }
            return self.panels.pageTurn.prepare(image: image, frame: self.store.layout.mainFrame, direction: direction)
        }
        store.onFinishPageTurn = { [weak self] in await self?.panels.pageTurn.finish() }
        store.onCancelPageTurn = { [weak self] in self?.panels.pageTurn.cancel() }
        store.onContinuousPreview = { [weak self] images, titles, layout in
            guard let self else { return }
            _ = self.panels.continuous.prepare(images: images, titles: titles, frame: layout.bookFrame,
                                               position: layout.position, mainRatio: self.store.ratio, frames: layout.frames)
        }
        store.onContinuousPositionChanged = { [weak self] layout in
            self?.panels.continuous.update(position: layout.position, frames: layout.frames)
        }
        store.onCancelContinuousPreview = { [weak self] in self?.panels.continuous.cancel() }
        if CommandLine.arguments.contains("--fixture-host") {
            store.fixtures.show()
            return
        }
        shortcuts = GlobalShortcuts { [weak self] action in self?.handle(action) }
        if let failures = shortcuts?.registrationFailures, !failures.isEmpty {
            store.message("部分快捷鍵已被其他工具使用：\(failures.joined(separator:"、"))。仍可使用畫面按鈕。",error:true)
        }
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName:"rectangle.3.group",accessibilityDescription:"WindowLane")
        let menu = NSMenu()
        menu.addItem(withTitle:"管理工作區",action:#selector(openManager),keyEquivalent:"").target = self
        menu.addItem(withTitle:"設定…",action:#selector(openSettings),keyEquivalent:"").target = self
        menu.addItem(withTitle:"退出並復原視窗",action:#selector(stopWorkspace),keyEquivalent:"").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle:"結束 WindowLane",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.menu = menu; statusItem = item
        showManager()
        if CommandLine.arguments.contains("--transfer-fixture") {
            let arguments = CommandLine.arguments
            let path = arguments.firstIndex(of: "--report-path").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                ?? "/tmp/WindowLane-transfer.json"
            let fixture = TransferFixture(reportURL: URL(fileURLWithPath: path))
            transferFixture = fixture; fixture.show(); store.loadNativeFixture(windows: fixture.windows)
            store.start()
            return
        }
        if CommandLine.arguments.contains("--demo") { store.loadDemo() }
        if CommandLine.arguments.contains("--background-smoke-test") {
            Task { @MainActor in
                let passed = await runBackgroundCheck()
                print(passed ? "BACKGROUND_SMOKE_PASS" : "BACKGROUND_SMOKE_FAIL")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds:300_000_000)
                let passed = await runSmokeCheck(store:store,managerWindow:manager,transition:panels.pageTurn)
                print(passed ? "NATIVE_SMOKE_PASS" : "NATIVE_SMOKE_FAIL")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--external-smoke-test") {
            Task { @MainActor in
                let passed = await runExternalCheck(store:store, transition:panels.pageTurn)
                print(passed ? "EXTERNAL_SMOKE_PASS" : "EXTERNAL_SMOKE_NOT_PASSED")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--obsidian-smoke-test") {
            Task { @MainActor in
                let passed = await runObsidianSizingCheck(store: store)
                print(passed ? "OBSIDIAN_SMOKE_PASS" : "OBSIDIAN_SMOKE_FAIL")
                NSApp.terminate(nil)
            }
        }
    }
    private func createMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle:"管理工作區",action:#selector(openManager),keyEquivalent:"0").target = self
        appMenu.addItem(withTitle:"設定…",action:#selector(openSettings),keyEquivalent:",").target = self
        appMenu.addItem(withTitle:"退出並復原視窗",action:#selector(stopWorkspace),keyEquivalent:"").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"結束 WindowLane",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title:"編輯")
        edit.addItem(withTitle:"復原",action:Selector(("undo:")),keyEquivalent:"z")
        edit.addItem(withTitle:"剪下",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"複製",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"貼上",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"全選",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    func handle(_ action: ShortcutAction) {
        switch action {
        case .previous: store.step(-1)
        case .next: store.step(1)
        case .select(let index): store.select(index:index)
        case .toggleExpanded: store.toggleExpanded()
        case .stop: store.stop(); showManager()
        case .addFrontmost: store.addFrontmost()
        case .showManager: store.stop(); showManager()
        }
    }
    @objc func openManager() { store.stop(); showManager() }
    @objc func stopWorkspace() { store.stop(); showManager() }
    @objc func openSettings() { showSettings() }
    func showSettings() {
        store.settingsPresentation = UUID()
        store.refreshPermissions()
        if settingsWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:580,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            window.title = "WindowLane 設定"
            window.identifier = NSUserInterfaceItemIdentifier("windowlane.settings")
            window.minSize = NSSize(width:540,height:520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.isOpaque = false; window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView:BackgroundSettingsView(store:store,onClose:{ [weak self] in
                self?.settingsWindow?.orderOut(nil)
                if self?.store.isRunning == true { self?.store.refocusActive() }
            }))
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func showManager() {
        store.refreshWindows()
        manager.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func windowWillClose(_ notification:Notification) {
        if notification.object as? NSWindow === settingsWindow { store.refocusActive() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { store.stop(); showManager(); return true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        store.stop()
        if store.isRestoring {
            terminationPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store.waitForRestoration()
                sender.reply(toApplicationShouldTerminate:true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification) {
        shortcuts?.unregister(); scrollRouter?.stopMonitoring(); panels?.hide(); transferFixture?.close()
    }
}

final class BackdropWindow: NSWindow {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
    override func accessibilityIsIgnored() -> Bool { true }
}

final class LanePanel: NSPanel {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
}
final class InputShieldPanel: NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
    override func keyDown(with event:NSEvent) {}
    override func keyUp(with event:NSEvent) {}
}

@MainActor final class WorkspacePanels {
    let store:WorkspaceStore
    let left = LanePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let right = LanePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let rail = LanePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let backdrop = BackdropWindow(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
    let pageTurn = PageTurnTransition()
    let continuous = ContinuousPagePresentation()
    lazy var dragTransfer = DragTransferRouter(
        isEnabled: { [weak self] in self?.store.isRunning == true && self?.store.isBusy == false && self?.store.expanded == false },
        canNavigate: { [weak self] direction in
            guard let self else { return false }
            return self.store.ordered.indices.contains(self.store.activeIndex + direction)
        },
        navigate: { [weak self] direction in self?.store.revealAdjacentForDrag(direction) })
    var shield: InputShieldPanel?
    init(store:WorkspaceStore) {
        self.store = store
        for panel in [left,right,rail] {
            panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
        }
        left.title = "上一個視窗預覽"
        right.title = "下一個視窗預覽"
        rail.title = "WindowLane 切換條"
        backdrop.title = "WindowLane 背景"
        left.contentView = EdgeDropHostingView(rootView:EdgeView(store:store,delta:-1), direction:-1, router:dragTransfer)
        right.contentView = EdgeDropHostingView(rootView:EdgeView(store:store,delta:1), direction:1, router:dragTransfer)
        rail.contentView = NSHostingView(rootView:RailView(store:store))
        backdrop.isOpaque = false
        backdrop.backgroundColor = .clear
        backdrop.contentView = NSHostingView(rootView: LaneWindowBackground(settings: store.background, surface: .workspace))
        backdrop.level = NSWindow.Level(rawValue:NSWindow.Level.normal.rawValue-1)
        backdrop.ignoresMouseEvents = true
        backdrop.isReleasedWhenClosed = false
        backdrop.hasShadow = false
    }
    func update() {
        guard store.isRunning else { hide(); return }
        let layout = store.layout
        backdrop.setFrame(store.screen.visibleFrame,display:true); backdrop.orderFrontRegardless()
        rail.setFrame(layout.railFrame,display:true); rail.orderFrontRegardless()
        if store.expanded || store.isSplit {
            if left.isVisible { left.orderOut(nil) }
            if right.isVisible { right.orderOut(nil) }
        }
        else {
            left.setFrame(layout.leftPreviewFrame,display:true); right.setFrame(layout.rightPreviewFrame,display:true)
            left.orderFrontRegardless(); right.orderFrontRegardless()
        }
    }
    func hide() { pageTurn.cancel(); continuous.cancel(); dragTransfer.cancel(); left.orderOut(nil); right.orderOut(nil); rail.orderOut(nil); backdrop.orderOut(nil); releaseInputShield() }
    func releaseInputShield() { shield?.orderOut(nil); shield = nil }
    func beginFocusHandoff() {
        releaseInputShield()
        let frame = store.layout.mainFrame
        let panel = InputShieldPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1)
        panel.isOpaque = false; panel.hasShadow = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame:NSRect(origin:.zero,size:frame.size))
        shield = panel
        panel.makeKeyAndOrderFront(nil)
    }
}
