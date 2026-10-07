import AppKit

/// App-owned editable documents for repeatable layout and text-state smoke tests.
@MainActor
final class FixtureWindows {
    private(set) var windows: [NSWindow] = []

    func show() {
        if windows.isEmpty {
            let examples: [(String, String)] = [
                ("Document A · 閱讀測試", "Document A — 閱讀與筆記\n\n這是 WindowLane 建立的測試視窗。\n你可以編輯這段文字、選取內容，再切換到另一個視窗。\n\n切換回來時，文字與選取範圍應保留。\n\n測試流程：\n1. 在下方輸入一行文字。\n2. 選取其中幾個字。\n3. 切換到 Document B。\n4. 回到這裡檢查狀態。\n\n我的測試筆記：\n"),
                ("Document B · 草稿測試", "Document B — 未完成的草稿\n\n此視窗是原生 NSTextView，可自由編輯。\n\nDear colleague,\n\nI am preparing a short note while keeping my reference document nearby.\n\n請在這裡加入自己的文字：\n"),
                ("Document C · 日語測試", "Document C — 日本語の練習\n\n今日のテーマ：文章を読みながら、気になった表現をメモする。\n\n語彙\n・切り替える（きりかえる）：切換\n・並べる（ならべる）：排列\n・作業（さぎょう）：工作、作業\n\n例文\n資料を読みながら、別のウィンドウにメモを書きます。\n\n自分の例文：\n")
            ]
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            for (index, example) in examples.enumerated() {
                let width = min(720, screenFrame.width * 0.65)
                let height = min(560, screenFrame.height * 0.75)
                let frame = NSRect(
                    x: screenFrame.minX + 50 + CGFloat(index) * 44,
                    y: screenFrame.maxY - height - 35 - CGFloat(index) * 35,
                    width: width,
                    height: height
                )
                let window = SizingFixtureWindow(
                    contentRect: frame,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = example.0
                window.identifier = NSUserInterfaceItemIdentifier("windowlane.fixture.\(index)")
                window.minSize = NSSize(width: 320, height: 220)
                window.isReleasedWhenClosed = false

                let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
                scrollView.autoresizingMask = [.width, .height]
                scrollView.hasVerticalScroller = true
                scrollView.borderType = .noBorder
                let textView = NSTextView(frame: scrollView.bounds)
                textView.autoresizingMask = [.width]
                textView.isVerticallyResizable = true
                textView.isHorizontallyResizable = false
                textView.textContainer?.widthTracksTextView = true
                textView.textContainerInset = NSSize(width: 24, height: 24)
                textView.font = NSFont.systemFont(ofSize: 17)
                textView.textColor = .labelColor
                textView.backgroundColor = .textBackgroundColor
                textView.isRichText = false
                textView.isAutomaticQuoteSubstitutionEnabled = false
                textView.allowsUndo = true
                textView.string = example.1
                textView.setAccessibilityIdentifier("windowlane.fixture.editor.\(index)")
                scrollView.documentView = textView
                window.contentView = scrollView
                window.initialFirstResponder = textView
                windows.append(window)
            }
        }
        windows.forEach { $0.orderFront(nil) }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}

/// Test fixture for applications that accept a resize request but clamp its width.
/// A zero bound retains the ordinary editable demonstration behavior.
final class SizingFixtureWindow: NSWindow {
    var imposedMinimumWidth: CGFloat = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        frame.size.width = max(frame.width, imposedMinimumWidth)
        super.setFrame(frame, display: flag)
    }
}
