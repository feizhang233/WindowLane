import AppKit
import CryptoKit

/// Explicit --transfer-fixture mode only. Every file is generated in a unique
/// temporary directory; this fixture never enumerates or opens user documents.
@MainActor final class TransferFixture {
    private(set) var windows: [NSWindow] = []
    let reportURL: URL
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowLane-transfer-\(UUID().uuidString)", isDirectory: true)
    private var expected: [URL: String] = [:]
    private var drops: [TransferFixtureDrop] = []
    private var startedSessions = 0
    private var endedSessions = 0
    private var lastOperation: UInt = 0
    private var error: String?

    init(reportURL: URL) { self.reportURL = reportURL }

    func show() {
        guard windows.isEmpty else {
            windows.forEach { $0.orderFront(nil) }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let textURL = directory.appendingPathComponent("WindowLane-test-document.txt")
            let imageURL = directory.appendingPathComponent("WindowLane-test-photo.png")
            let text = Data("WindowLane native drag transfer fixture.\n文件與圖片僅供測試。\n".utf8)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32,
                pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw TransferFixtureError.imageCreation
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 16, height: 16)).fill()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw TransferFixtureError.imageCreation
            }
            try text.write(to: textURL, options: .atomic)
            try png.write(to: imageURL, options: .atomic)
            expected = [textURL: Self.hash(text), imageURL: Self.hash(png)]

            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: min(800, screen.width * 0.65), height: min(600, screen.height * 0.75))
            let source = makeWindow(title: "拖曳來源 · 測試文件與圖片", identifier: "windowlane.transfer.source",
                frame: NSRect(x: screen.minX + 30, y: screen.maxY - size.height - 30, width: size.width, height: size.height))
            let destination = makeWindow(title: "拖曳目標 · 原生接收區", identifier: "windowlane.transfer.target",
                frame: NSRect(x: screen.minX + 100, y: screen.maxY - size.height - 100, width: size.width, height: size.height))
            let sourceView = TransferSourceContainer(frame: NSRect(origin: .zero, size: size))
            for (index, url) in [textURL, imageURL].enumerated() {
                let item = TransferSourceItem(url: url, isImage: index == 1,
                    onStarted: { [weak self] in
                        guard let self else { return }
                        self.startedSessions += 1
                        self.writeReport()
                    }, onEnded: { [weak self] operation in
                        guard let self else { return }
                        self.endedSessions += 1
                        self.lastOperation = operation.rawValue
                        self.writeReport()
                    })
                sourceView.items.append(item)
                sourceView.addSubview(item)
            }
            source.contentView = sourceView
            let target = TransferDestinationView(frame: NSRect(origin: .zero, size: size),
                accepts: { [weak self] urls in
                    guard let self else { return false }
                    return !urls.isEmpty && urls.allSatisfy { self.expected[$0] != nil }
                }, receive: { [weak self] urls, sequence in
                    self?.receive(urls, sequence: sequence) ?? false
                })
            destination.contentView = target
            windows = [source, destination]
            sourceView.needsLayout = true
            sourceView.layoutSubtreeIfNeeded()
            writeReport()
            windows.forEach { $0.orderFront(nil) }
            source.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            self.error = error.localizedDescription
            writeReport()
        }
    }

    func close() {
        windows.forEach { $0.close() }
        windows.removeAll()
        // Keep generated files alongside the report for byte-level audit.
    }

    private func makeWindow(title: String, identifier: String, frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.minSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false
        return window
    }

    private func receive(_ urls: [URL], sequence: Int) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy({ expected[$0] != nil }) else { return false }
        do {
            let destination = directory.appendingPathComponent("received", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var received: [TransferFixtureDrop] = []
            for url in urls {
                guard let expectedHash = expected[url] else { return false }
                let sourceData = try Data(contentsOf: url)
                guard Self.hash(sourceData) == expectedHash else { throw TransferFixtureError.sourceChanged }
                let copyURL = destination.appendingPathComponent("\(drops.count + received.count + 1)-\(url.lastPathComponent)")
                try sourceData.write(to: copyURL, options: .atomic)
                let receivedHash = Self.hash(try Data(contentsOf: copyURL))
                guard receivedHash == expectedHash else { throw TransferFixtureError.receivedChanged }
                received.append(TransferFixtureDrop(name: url.lastPathComponent,
                    kind: url.pathExtension == "png" ? "image" : "file",
                    sequence: sequence, receivedAt: Date(), sourcePath: url.path,
                    receivedPath: copyURL.path, expectedSHA256: expectedHash,
                    receivedSHA256: receivedHash, bytes: sourceData.count))
            }
            drops.append(contentsOf: received)
            error = nil
            writeReport()
            (windows.last?.contentView as? TransferDestinationView)?.receivedNames = drops.map(\.name)
            return true
        } catch {
            self.error = error.localizedDescription
            writeReport()
            return false
        }
    }

    private func writeReport() {
        let unchanged = !expected.isEmpty && expected.allSatisfy { url, hash in
            (try? Data(contentsOf: url)).map(Self.hash) == hash
        }
        let report = TransferFixtureReport(completedAt: Date(), directory: directory.path,
            count: drops.count, textVerified: drops.contains { $0.kind == "file" },
            imageVerified: drops.contains { $0.kind == "image" }, sourceUnchanged: unchanged,
            startedSessions: startedSessions, endedSessions: endedSessions,
            lastOperation: lastOperation, drops: drops, error: error)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch { print("WINDOWLANE_TRANSFER_REPORT_ERROR \(error.localizedDescription)") }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum TransferFixtureError: LocalizedError {
    case imageCreation, sourceChanged, receivedChanged
    var errorDescription: String? {
        switch self {
        case .imageCreation: return "測試圖片無法建立。"
        case .sourceChanged: return "測試來源的內容已改變。"
        case .receivedChanged: return "接收副本與測試來源不符。"
        }
    }
}

private struct TransferFixtureDrop: Encodable {
    let name: String
    let kind: String
    let sequence: Int
    let receivedAt: Date
    let sourcePath: String
    let receivedPath: String
    let expectedSHA256: String
    let receivedSHA256: String
    let bytes: Int
}

private struct TransferFixtureReport: Encodable {
    let schemaVersion = 1
    let scope = "native-drag-two-fixture-windows"
    let limitation = "App-owned source and destination only. This verifies original NSDraggingSession file-URL transfer, not arbitrary external applications, file promises or inline photo data."
    let completedAt: Date
    let directory: String
    let count: Int
    let textVerified: Bool
    let imageVerified: Bool
    let sourceUnchanged: Bool
    let startedSessions: Int
    let endedSessions: Int
    let lastOperation: UInt
    let drops: [TransferFixtureDrop]
    let error: String?
}

@MainActor private final class TransferSourceContainer: NSView {
    var items: [TransferSourceItem] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("Fixture is constructed programmatically") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for (index, item) in items.enumerated() {
            item.frame = NSRect(x: 24, y: bounds.maxY - 140 - CGFloat(index) * 125,
                width: max(180, bounds.width - 48), height: 100)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        drawFixtureText("把文件或圖片拖曳到右側視窗", at: NSPoint(x: 24, y: 24), font: .systemFont(ofSize: 16), color: .secondaryLabelColor)
    }
}

@MainActor private final class TransferSourceItem: NSView, NSDraggingSource {
    private let url: URL
    private let isImage: Bool
    private let onStarted: () -> Void
    private let onEnded: (NSDragOperation) -> Void
    private var mouseDownPoint: CGPoint?
    private var dragging = false

    init(url: URL, isImage: Bool, onStarted: @escaping () -> Void,
         onEnded: @escaping (NSDragOperation) -> Void) {
        self.url = url; self.isImage = isImage
        self.onStarted = onStarted; self.onEnded = onEnded
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(isImage ? "拖曳測試圖片" : "拖曳測試文件")
        setAccessibilityIdentifier("windowlane.transfer.source.\(isImage ? "image" : "file")")
    }
    required init?(coder: NSCoder) { fatalError("Fixture is constructed programmatically") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let initial = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - initial.x, point.y - initial.y) >= 4 else { return }
        dragging = true
        mouseDownPoint = nil
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 48, height: 48)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onStarted() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; mouseDownPoint = nil; onEnded(operation)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).stroke()
        drawFixtureText(isImage ? "拖曳測試圖片" : "拖曳測試文件", at: NSPoint(x: 20, y: 53), font: .systemFont(ofSize: 20, weight: .semibold))
        drawFixtureText(url.lastPathComponent, at: NSPoint(x: 20, y: 24), font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    }
}

@MainActor private final class TransferDestinationView: NSView {
    private let accepts: ([URL]) -> Bool
    private let receive: ([URL], Int) -> Bool
    private var hovered = false
    var receivedNames: [String] = [] {
        didSet {
            setAccessibilityValue("已接收 \(receivedNames.count) 項：\(receivedNames.joined(separator: "、"))")
            needsDisplay = true
        }
    }
    init(frame: NSRect, accepts: @escaping ([URL]) -> Bool, receive: @escaping ([URL], Int) -> Bool) {
        self.accepts = accepts; self.receive = receive
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("原生文件與圖片接收區")
        setAccessibilityIdentifier("windowlane.transfer.destination")
        setAccessibilityValue("已接收 0 項")
    }
    required init?(coder: NSCoder) { fatalError("Fixture is constructed programmatically") }
    private func URLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hovered = sender.draggingSourceOperationMask.contains(.copy) && accepts(URLs(sender))
        needsDisplay = true
        return hovered ? .copy : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { hovered = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingSourceOperationMask.contains(.copy) && accepts(URLs(sender))
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        hovered = false; needsDisplay = true
        return receive(URLs(sender), sender.draggingSequenceNumber)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let area = bounds.insetBy(dx: 24, dy: 24)
        (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        NSBezierPath(roundedRect: area, xRadius: 16, yRadius: 16).fill()
        (hovered ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let outline = NSBezierPath(roundedRect: area, xRadius: 16, yRadius: 16)
        outline.lineWidth = 2; outline.stroke()
        drawFixtureText("在此放開文件或圖片", at: NSPoint(x: 45, y: bounds.maxY - 90), font: .systemFont(ofSize: 22, weight: .semibold))
        drawFixtureText("已接收 \(receivedNames.count) 項", at: NSPoint(x: 45, y: bounds.maxY - 130), font: .systemFont(ofSize: 17))
        for (index, name) in receivedNames.suffix(5).enumerated() {
            drawFixtureText(name, at: NSPoint(x: 45, y: bounds.maxY - 175 - CGFloat(index) * 26), font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
        }
    }
}

@MainActor private func drawFixtureText(_ text: String, at point: NSPoint,
                                      font: NSFont, color: NSColor = .labelColor) {
    (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}
